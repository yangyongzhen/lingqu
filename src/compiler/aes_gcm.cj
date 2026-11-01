package lingqu.compiler

import std.collection.*

/*
 * 纯仓颉 AES-128-GCM（0.39.13）。
 *
 * **为什么自己写**：仓颉 std / stdx 1.0.5.1 **没有 AES**——`stdx.crypto.crypto` 只给 `SM4`，
 * 标准库 `std.crypto.cipher` 只有 `BlockCipher` 接口；本机实测 SM4-GCM 直接抛
 * `CryptoException: Encrypt failed due to create tag error`（CBC/ECB/CTR 才可用）。
 * 而 hvigor 的 `AesGcmKit` 口令密文就是 AES-128-GCM，绕不开。
 *
 * **可信度**：NIST TC1/TC2/TC4、非 96bit nonce、多块、tag 篡改拒绝共 10 项向量全过
 * （对照实现为 pycryptodome，与 RFC 公布值一致），见 `src/tests/aes_gcm_test.cj`。
 *
 * **边界**：只支持 AES-128（16B key）；未优化（S-box 表 + 逐 bit GHASH），
 * 只用于口令/令牌这种几十字节数据，**不要**拿去加密大文件。
 *
 * 加密输出 `ciphertext || tag(16B)`；解密时 tag 不符抛 `IllegalArgumentException`（常数时间比较）。
 */

// ---------- AES-128 (ECB core) ----------
let AES_SBOX: Array<Byte> = [
    0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B, 0xFE, 0xD7, 0xAB, 0x76,
    0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0, 0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0,
    0xB7, 0xFD, 0x93, 0x26, 0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
    0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2, 0xEB, 0x27, 0xB2, 0x75,
    0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0, 0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84,
    0x53, 0xD1, 0x00, 0xED, 0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
    0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F, 0x50, 0x3C, 0x9F, 0xA8,
    0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5, 0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2,
    0xCD, 0x0C, 0x13, 0xEC, 0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
    0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14, 0xDE, 0x5E, 0x0B, 0xDB,
    0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C, 0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79,
    0xE7, 0xC8, 0x37, 0x6D, 0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
    0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F, 0x4B, 0xBD, 0x8B, 0x8A,
    0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E, 0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E,
    0xE1, 0xF8, 0x98, 0x11, 0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
    0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F, 0xB0, 0x54, 0xBB, 0x16
]

func xtime(x: Int64): Int64 {
    let v = (x << 1) & 0x1FF
    if ((v & 0x100) != 0) {
        return (v & 0xFF) ^ 0x1B
    }
    return v & 0xFF
}

func expandKey128(key: Array<Byte>): Array<Byte> {
    let w = Array<Byte>(176, repeat: 0)
    for (i in 0..16) {
        w[i] = key[i]
    }
    var rcon: Int64 = 1
    var i: Int64 = 16
    while (i < 176) {
        var t = Array<Int64>(4, repeat: 0)
        for (j in 0..4) {
            t[j] = Int64(w[i - 4 + j])
        }
        if (i % 16 == 0) {
            let tmp = t[0]
            t[0] = Int64(AES_SBOX[t[1]])
            t[1] = Int64(AES_SBOX[t[2]])
            t[2] = Int64(AES_SBOX[t[3]])
            t[3] = Int64(AES_SBOX[tmp])
            t[0] = t[0] ^ rcon
            rcon = xtime(rcon)
        }
        for (j in 0..4) {
            w[i + j] = UInt8((Int64(w[i - 16 + j]) ^ t[j]) & 0xFF)
        }
        i = i + 4
    }
    return w
}

func encryptBlock128(rk: Array<Byte>, input: Array<Byte>): Array<Byte> {
    var s = Array<Int64>(16, repeat: 0)
    for (i in 0..16) {
        s[i] = Int64(input[i]) ^ Int64(rk[i])
    }
    for (round in 1..=10) {
        // SubBytes + ShiftRows（state 按列存放：s[4*c + r]）
        let t = Array<Int64>(16, repeat: 0)
        for (c in 0..4) {
            for (r in 0..4) {
                t[4 * c + r] = Int64(AES_SBOX[s[4 * ((c + r) % 4) + r]])
            }
        }
        for (k in 0..16) {
            s[k] = t[k]
        }
        if (round != 10) {
            // MixColumns
            for (c in 0..4) {
                let a0 = s[4 * c + 0]
                let a1 = s[4 * c + 1]
                let a2 = s[4 * c + 2]
                let a3 = s[4 * c + 3]
                s[4 * c + 0] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3
                s[4 * c + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3
                s[4 * c + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3)
                s[4 * c + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3)
            }
        }
        // AddRoundKey
        for (k in 0..16) {
            s[k] = s[k] ^ Int64(rk[16 * round + k])
        }
    }
    let out = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        out[i] = UInt8(s[i] & 0xFF)
    }
    return out
}

// ---------- GF(2^128) 乘法（GHASH 用） ----------
func xor16(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
    let r = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        r[i] = a[i] ^ b[i]
    }
    return r
}

func gf128Mul(x: Array<Byte>, y: Array<Byte>): Array<Byte> {
    var z = Array<Int64>(16, repeat: 0)
    var v = Array<Int64>(16, repeat: 0)
    for (i in 0..16) {
        v[i] = Int64(y[i])
    }
    for (i in 0..128) {
        let bit = (Int64(x[i / 8]) >> (7 - (i % 8))) & 1
        if (bit == 1) {
            for (k in 0..16) {
                z[k] = z[k] ^ v[k]
            }
        }
        let lsb = v[15] & 1
        var carry: Int64 = 0
        for (k in 0..16) {
            let cur = v[k]
            v[k] = (cur >> 1) | (carry << 7)
            carry = cur & 1
        }
        if (lsb == 1) {
            v[0] = v[0] ^ 0xE1
        }
    }
    let out = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        out[i] = UInt8(z[i] & 0xFF)
    }
    return out
}

func absorb(s0: Array<Byte>, h: Array<Byte>, data: Array<Byte>): Array<Byte> {
    var s = s0
    var i: Int64 = 0
    while (i < data.size) {
        let blk = Array<Byte>(16, repeat: 0)
        var n: Int64 = 0
        while (n < 16 && i + n < data.size) {
            blk[n] = data[i + n]
            n = n + 1
        }
        s = gf128Mul(xor16(s, blk), h)
        i = i + 16
    }
    return s
}

func putBe64(buf: Array<Byte>, off: Int64, value: Int64) {
    for (i in 0..8) {
        buf[off + i] = UInt8((value >> (56 - 8 * i)) & 0xFF)
    }
}

func inc32(ctr: Array<Byte>) {
    for (i in 0..4) {
        let idx = 15 - i
        if (ctr[idx] == 0xFF) {
            ctr[idx] = 0
        } else {
            ctr[idx] = ctr[idx] + 1
            return
        }
    }
}

func j0Of(nonce: Array<Byte>, h: Array<Byte>): Array<Byte> {
    if (nonce.size == 12) {
        let j = Array<Byte>(16, repeat: 0)
        for (i in 0..12) {
            j[i] = nonce[i]
        }
        j[15] = 1
        return j
    }
    var s = absorb(Array<Byte>(16, repeat: 0), h, nonce)
    let lenBlk = Array<Byte>(16, repeat: 0)
    putBe64(lenBlk, 8, nonce.size * 8)
    return gf128Mul(xor16(s, lenBlk), h)
}

// ---------- 对外 API ----------
// 加密：返回 ciphertext || tag(16B)
public func aes128GcmEncrypt(key: Array<Byte>, nonce: Array<Byte>, plaintext: Array<Byte>, aad: Array<Byte>): Array<Byte> {
    if (key.size != 16) {
        throw IllegalArgumentException("AES-128 key must be 16 bytes, got ${key.size}")
    }
    if (nonce.size == 0) {
        throw IllegalArgumentException("nonce must not be empty")
    }
    let rk = expandKey128(key)
    let h = encryptBlock128(rk, Array<Byte>(16, repeat: 0))
    let j0 = j0Of(nonce, h)
    // CTR
    let out = ArrayList<Byte>()
    let ctr = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        ctr[i] = j0[i]
    }
    var i: Int64 = 0
    while (i < plaintext.size) {
        inc32(ctr)
        let ks = encryptBlock128(rk, ctr)
        var n: Int64 = 0
        while (n < 16 && i + n < plaintext.size) {
            out.add(plaintext[i + n] ^ ks[n])
            n = n + 1
        }
        i = i + 16
    }
    let ct = out.toArray()
    // tag
    var s = absorb(Array<Byte>(16, repeat: 0), h, aad)
    s = absorb(s, h, ct)
    let lenBlk = Array<Byte>(16, repeat: 0)
    putBe64(lenBlk, 0, aad.size * 8)
    putBe64(lenBlk, 8, ct.size * 8)
    s = gf128Mul(xor16(s, lenBlk), h)
    let tag = xor16(encryptBlock128(rk, j0), s)
    let sealed = ArrayList<Byte>()
    sealed.add(all: ct)
    sealed.add(all: tag)
    return sealed.toArray()
}

// 解密：输入 ciphertext || tag(16B)，tag 不符抛 IllegalArgumentException
public func aes128GcmDecrypt(key: Array<Byte>, nonce: Array<Byte>, sealed: Array<Byte>, aad: Array<Byte>): Array<Byte> {
    if (sealed.size < 16) {
        throw IllegalArgumentException("sealed data shorter than 16-byte tag")
    }
    let ctLen = sealed.size - 16
    let ct = sealed[0..ctLen]
    let tag = sealed[ctLen..sealed.size]
    let rk = expandKey128(key)
    let h = encryptBlock128(rk, Array<Byte>(16, repeat: 0))
    let j0 = j0Of(nonce, h)
    var s = absorb(Array<Byte>(16, repeat: 0), h, aad)
    s = absorb(s, h, ct)
    let lenBlk = Array<Byte>(16, repeat: 0)
    putBe64(lenBlk, 0, aad.size * 8)
    putBe64(lenBlk, 8, ct.size * 8)
    s = gf128Mul(xor16(s, lenBlk), h)
    let expect = xor16(encryptBlock128(rk, j0), s)
    var diff: Int64 = 0
    for (i in 0..16) {
        diff = diff | (Int64(expect[i] ^ tag[i]))
    }
    if (diff != 0) {
        throw IllegalArgumentException("GCM tag mismatch")
    }
    // CTR
    let out = ArrayList<Byte>()
    let ctr = Array<Byte>(16, repeat: 0)
    for (i in 0..16) {
        ctr[i] = j0[i]
    }
    var i: Int64 = 0
    while (i < ct.size) {
        inc32(ctr)
        let ks = encryptBlock128(rk, ctr)
        var n: Int64 = 0
        while (n < 16 && i + n < ct.size) {
            out.add(ct[i + n] ^ ks[n])
            n = n + 1
        }
        i = i + 16
    }
    return out.toArray()
}