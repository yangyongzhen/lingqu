package lingqu.compiler

import std.collection.*
import std.fs.*
import std.time.*
import stdx.crypto.crypto.SecureRandom
import stdx.crypto.digest.*

/*
 * hvigor `AesGcmKit` 兼容的口令加解密（0.39.13）。
 *
 * 为什么需要它：写进 `build-profile.json5` 的 `storePassword` / `keyPassword` **不是明文**，
 * 而是 DevEco/hvigor 的 `AesGcmKit` 密文；hvigor 在 `SignHap` 时用它解开 `.p12`。
 * 我们想"全新生成一套签名材料"，就必须能**自己造这个密文**，否则只能抄别人的。
 *
 * 算法（逐条对齐 `hvigor-ohos-plugin` 的 `decipher-util.js` 与 flutter
 * `lib/src/ohos/signing/keymanager.dart`，见 docs/鸿蒙自动签名机制.md §3.7b）：
 *
 *   material/{ac, ce, fd/0,1,2}      每个目录**恰好一个**文件（随机 32 hex 文件名）
 *   passphrase = lossyUtf8( XOR(fd0, fd1, fd2, FIXED16) )
 *   rootKey    = PBKDF2-HMAC-SHA256(passphrase, salt, 10000, 16)
 *   workKey    = AES-128-GCM-decrypt(rootKey, payload(ce))
 *   ciphertext = hex( payload( AES-128-GCM-encrypt(workKey, password) ) )
 *   payload(x) = [ len(4B BE)=|ct|+16 | IV(12) | ct | tag(16) ]
 *
 * 两个只在源码里才能看到的细节，这里都照做了：
 *   ① `lossyUtf8`：Node 的 `Buffer.toString('utf8')` 会把**非法序列换成 U+FFFD**，
 *      再编码回 UTF-8 才喂给 PBKDF2。若直接拿原始字节做 PBKDF2，rootKey 必然不同；
 *   ② **`material/` 是 `~/.ohos/config` 级共享的**（不是每个 p12 一套），
 *      所以同一台机器上新造的口令密文，hvigor 也能解开。
 */

/** AesGcmKit 的 16 字节固定分量（源码常量，别改） */
public let AES_GCM_KIT_FIXED: Array<Byte> = [
    0x31, 0xf3, 0x09, 0x73, 0xd6, 0xaf, 0x5b, 0xb8, 0xd3, 0xbe, 0xb1, 0x58, 0x65, 0x83, 0xc0, 0x77
]

/** HMAC-SHA256（32B） */
public func hmacSha256(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
    let mac = HMAC(key, HashType.SHA256)
    mac.write(data)
    return mac.finish()
}

/**
 * PBKDF2-HMAC-SHA256（RFC 8018）。stdx 没有现成实现，自己写。
 *
 * 已用公开向量核对（`password`/`salt`、c=1/2/4096、dkLen=32）与
 * `hashlib.pbkdf2_hmac('sha256', …)` 逐字节一致，见 `src/tests/aes_gcm_kit_test.cj`。
 */
public func pbkdf2HmacSha256(password: Array<Byte>, salt: Array<Byte>, iterations: Int64,
    dkLen: Int64): Array<Byte> {
    let hLen: Int64 = 32
    let blocks: Int64 = (dkLen + hLen - 1) / hLen
    let out = ArrayList<Byte>()
    var i: Int64 = 1
    while (i <= blocks) {
        // U1 = HMAC(password, salt || INT32BE(i))
        let first = ArrayList<Byte>()
        first.add(all: salt)
        first.add(UInt8((i >> 24) & 0xFF))
        first.add(UInt8((i >> 16) & 0xFF))
        first.add(UInt8((i >> 8) & 0xFF))
        first.add(UInt8(i & 0xFF))
        var u: Array<Byte> = hmacSha256(password, first.toArray())
        let acc = u.clone()
        var j: Int64 = 1
        while (j < iterations) {
            u = hmacSha256(password, u)
            for (k in 0..acc.size) {
                acc[k] = acc[k] ^ u[k]
            }
            j += 1
        }
        out.add(all: acc)
        i += 1
    }
    let all = out.toArray()
    return all[0..dkLen]
}

/**
 * 有损 UTF-8 规范化：合法序列原样保留，**非法序列按一个 U+FFFD（EF BF BD）替换**。
 *
 * 与 Node `Buffer.toString('utf8')` / Dart `utf8.decode(allowMalformed: true)` 同语义——
 * AesGcmKit 的 passphrase 就是这么来的。不这么做的后果：rootKey 对不上，
 * 解出的 workKey 是错的，最后 hvigor 报"签名失败"而不会说"你的 UTF-8 处理错了"。
 */
public func lossyUtf8Bytes(data: Array<Byte>): Array<Byte> {
    let out = ArrayList<Byte>()
    var i: Int64 = 0
    let n = Int64(data.size)
    while (i < n) {
        let b = Int64(data[i])
        var need: Int64 = 0
        var cp: Int64 = 0
        if (b < 0x80) {
            out.add(UInt8(b))
            i += 1
            continue
        } else if ((b & 0xE0) == 0xC0) {
            need = 1
            cp = b & 0x1F
        } else if ((b & 0xF0) == 0xE0) {
            need = 2
            cp = b & 0x0F
        } else if ((b & 0xF8) == 0xF0) {
            need = 3
            cp = b & 0x07
        } else {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        if (i + need >= n) {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        var ok = true
        var k: Int64 = 1
        while (k <= need) {
            let c = Int64(data[i + k])
            if ((c & 0xC0) != 0x80) {
                ok = false
                break
            }
            cp = (cp << 6) | (c & 0x3F)
            k += 1
        }
        // 过长编码 / 代理区 / 超范围都算非法（Node 同款判断）
        if (ok) {
            let minCp = if (need == 1) { 0x80 } else if (need == 2) { 0x800 } else { 0x10000 }
            if (cp < minCp || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
                ok = false
            }
        }
        if (!ok) {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        for (m in 0..(need + 1)) {
            out.add(data[i + m])
        }
        i += need + 1
    }
    return out.toArray()
}

/** 读目录里**恰好一个**文件的字节（0 个或多个都算错：DevEco 的约定是"一个目录一个文件"） */
func readUniqueFileBytes(dir: String): (Array<Byte>, String) {
    if (!exists(Path(dir))) {
        return ([], "目录不存在：${dir}")
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        return ([], "读目录失败 ${dir}：${e}")
    }
    let files = ArrayList<String>()
    for (info in entries) {
        if (!info.isDirectory() && info.name != ".DS_Store") {
            files.add("${dir}/${info.name}")
        }
    }
    if (files.size != 1) {
        return ([], "期望 ${dir} 下恰好 1 个文件，实际 ${files.size} 个")
    }
    try {
        return (File.readFrom(files[0]), "")
    } catch (e: Exception) {
        return ([], "读文件失败 ${files[0]}：${e}")
    }
}

/** material 目录（与 `.p12` 同级） */
public func materialDirOfConfig(configDir: String): String {
    return "${configDir}/material"
}

/**
 * 从 `material/` 解出 workKey（AES-128 的 16 字节）。
 *
 * 失败一律带原因返回（不静默）：材料缺文件、长度不对、GCM 认证失败，都要能说清是哪一步。
 */
public func loadWorkKey(materialDir: String): (Array<Byte>, String) {
    let (salt, e1) = readUniqueFileBytes("${materialDir}/ac")
    if (e1 != "") {
        return ([], "盐（material/ac）：${e1}")
    }
    if (salt.size != AES_GCM_KEY_LEN) {
        return ([], "盐长度应为 ${AES_GCM_KEY_LEN}，实际 ${salt.size}")
    }
    let (ce, e2) = readUniqueFileBytes("${materialDir}/ce")
    if (e2 != "") {
        return ([], "workKey 密文（material/ce）：${e2}")
    }
    let comps = ArrayList<Array<Byte>>()
    for (i in 0..3) {
        let (c, ec) = readUniqueFileBytes("${materialDir}/fd/${i}")
        if (ec != "") {
            return ([], "随机分量 fd/${i}：${ec}")
        }
        if (c.size != AES_GCM_KEY_LEN) {
            return ([], "随机分量 fd/${i} 长度应为 ${AES_GCM_KEY_LEN}，实际 ${c.size}")
        }
        comps.add(c)
    }
    // passphrase = lossyUtf8(XOR(三个分量, 固定分量))
    let xored = Array<Byte>(AES_GCM_KEY_LEN, repeat: 0)
    for (c in comps) {
        for (i in 0..AES_GCM_KEY_LEN) {
            xored[i] = xored[i] ^ c[i]
        }
    }
    for (i in 0..AES_GCM_KEY_LEN) {
        xored[i] = xored[i] ^ AES_GCM_KIT_FIXED[i]
    }
    let passphrase = lossyUtf8Bytes(xored)
    let rootKey = pbkdf2HmacSha256(passphrase, salt, PBKDF2_ITERATIONS, AES_GCM_KEY_LEN)
    match (unpackGcmPayload(ce)) {
        case Some(p) =>
            var workKey: Array<Byte> = []
            try {
                workKey = aes128GcmDecrypt(rootKey, p.iv, concatBytes(p.ciphertext, p.tag), Array<Byte>())
            } catch (e: Exception) {
                return ([], "解 workKey 失败（material/ 与口令不配套）：${e}")
            }
            return (workKey, "")
        case None =>
            return ([], "material/ce 载荷格式不对（应为 len|iv|ct|tag）")
    }
}

/** 拼两段字节 */
public func concatBytes(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
    let out = ArrayList<Byte>()
    out.add(all: a)
    out.add(all: b)
    return out.toArray()
}

/**
 * 口令 → `build-profile.json5` 里能直接写的那串 hex（AesGcmKit 兼容）。
 *
 * 每次调用 IV 随机 → **同一口令两次加密结果不同**（与 DevEco 一致，别写相等断言）。
 */
public func encryptPasswordHex(workKey: Array<Byte>, password: String): (String, String) {
    if (workKey.size != AES_GCM_KEY_LEN) {
        return ("", "workKey 长度应为 ${AES_GCM_KEY_LEN}，实际 ${workKey.size}")
    }
    let iv = randomBytes(AES_GCM_IV_LEN)
    let sealed = aes128GcmEncrypt(workKey, iv, password.toArray(), Array<Byte>())
    let ctLen = Int64(sealed.size) - AES_GCM_TAG_LEN
    if (ctLen < 0) {
        return ("", "GCM 输出异常（长度 ${sealed.size}）")
    }
    let ct = sealed[0..ctLen]
    let tag = sealed[ctLen..sealed.size]
    match (packGcmPayload(iv, ct, tag)) {
        case Some(raw) => return (toHexLower(raw), "")
        case None => return ("", "载荷打包失败（IV/tag 长度异常）")
    }
}

/** 反向：hex 密文 + workKey → 明文口令（自检用：证明我们写的密文 hvigor 也解得开） */
public func decryptPasswordHex(workKey: Array<Byte>, hex: String): (String, String) {
    match (fromHexLower(hex)) {
        case Some(raw) =>
            match (unpackGcmPayload(raw)) {
                case Some(p) =>
                    try {
                        let plain = aes128GcmDecrypt(workKey, p.iv,
                            concatBytes(p.ciphertext, p.tag), Array<Byte>())
                        return (String.fromUtf8(plain), "")
                    } catch (e: Exception) {
                        return ("", "口令解密失败：${e}")
                    }
                case None =>
                    return ("", "口令密文载荷格式不对")
            }
        case None =>
            return ("", "口令密文不是合法 hex")
    }
}

/** 系统随机源（拿不到返回 None，由调用方兜底） */
func secureRandomBytes(n: Int64): Option<Array<Byte>> {
    try {
        // 注意：`nextBytes` 的参数是 **Array<UInt8> 缓冲区**（不是长度），长度从 `.size` 来
        let buf = Array<Byte>(n, repeat: 0)
        SecureRandom().nextBytes(buf)
        return Some(buf)
    } catch (e: Exception) {
        let _ = e
        return None
    }
}

/** 随机字节（口令 / IV 用；系统随机源拿不到时退到时间种子，仅影响不可预测性不影响正确性） */
public func randomBytes(n: Int64): Array<Byte> {
    let filled: Option<Array<Byte>> = secureRandomBytes(n)
    match (filled) {
        case Some(b) => return b
        case None =>
            let out = Array<Byte>(n, repeat: 0)
            var seed = Int64(DateTime.now().toUnixTimeStamp().toNanoseconds()) & 0x7FFFFFFFFFFFFFFF
            for (i in 0..n) {
                seed = (seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF
                out[i] = UInt8((seed >> 33) & 0xFF)
            }
            return out
    }
}
