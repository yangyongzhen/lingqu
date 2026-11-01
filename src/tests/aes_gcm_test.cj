package lingqu.tests

import lingqu.compiler.*

/*
 * 纯仓颉 AES-128-GCM 的向量测试（0.39.13）。
 *
 * 期望值**不是自己算的**：TC1/TC2/TC4 是 NIST SP 800-38D 的公开测试向量，
 * 本轮又用本机 Node（DevEco 自带 node，走 OpenSSL）独立复算了一遍，逐字一致：
 *   TC1 tag 58e2fccefa7e3061367f1d57a4e7455a（明文为空，只验 tag）
 *   TC2 ct  0388dace60b6a392f328c2b971b2fe78 / tag ab6e47d42cec13bdf53a67b21257bddf
 *   TC4 ct  42831ec2…e091（60B 明文 + 20B AAD）/ tag 5bc94fbc3221a5db94fae95ae7121a47
 *
 * 为什么这段代码值得单测：它是 hvigor `AesGcmKit` 口令密文的最后一块拼图——
 * 算错一位，hvigor 只会说"签名失败"，不会说"你的 GCM 错了"。
 */

func hx(s: String): Array<Byte> {
    match (fromHexLower(s)) {
        case Some(b) => return b
        case None => return Array<Byte>()
    }
}

@Test
public func testAesGcmNistTc1EmptyPlaintext(): Unit {
    let key = hx("00000000000000000000000000000000")
    let iv = hx("000000000000000000000000")
    let sealed = aes128GcmEncrypt(key, iv, Array<Byte>(), Array<Byte>())
    // 空明文 → 只有 16B tag
    @Assert(sealed.size, 16)
    @Assert(toHexLower(sealed), "58e2fccefa7e3061367f1d57a4e7455a")
}

@Test
public func testAesGcmNistTc2OneBlock(): Unit {
    let key = hx("00000000000000000000000000000000")
    let iv = hx("000000000000000000000000")
    let pt = hx("00000000000000000000000000000000")
    let sealed = aes128GcmEncrypt(key, iv, pt, Array<Byte>())
    @Assert(sealed.size, 32)                       // 16B ct + 16B tag
    @Assert(toHexLower(sealed), "0388dace60b6a392f328c2b971b2fe78" +
        "ab6e47d42cec13bdf53a67b21257bddf")
}

@Test
public func testAesGcmNistTc4WithAad(): Unit {
    let key = hx("feffe9928665731c6d6a8f9467308308")
    let iv = hx("cafebabefacedbaddecaf888")
    let pt = hx("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
        "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
    let aad = hx("feedfacedeadbeeffeedfacedeadbeefabaddad2")
    let sealed = aes128GcmEncrypt(key, iv, pt, aad)
    @Assert(sealed.size, 76)                       // 60 + 16
    @Assert(toHexLower(sealed), "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e" +
        "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091" +
        "5bc94fbc3221a5db94fae95ae7121a47")
    // 解密回到明文（AAD 必须参与校验）
    let plain = aes128GcmDecrypt(key, iv, sealed, aad)
    @Assert(toHexLower(plain), toHexLower(pt))
}

@Test
public func testAesGcmRoundTripAndTamper(): Unit {
    let key = hx("feffe9928665731c6d6a8f9467308308")
    let iv = hx("cafebabefacedbaddecaf888")
    let pt = "口令-abc123".toArray()
    let sealed = aes128GcmEncrypt(key, iv, pt, Array<Byte>())
    @Assert(toHexLower(aes128GcmDecrypt(key, iv, sealed, Array<Byte>())), toHexLower(pt))
    // 改 tag 最后一位 → 必须拒绝（常数时间比较，不是"看起来对就算对"）
    let bad = sealed.clone()
    bad[bad.size - 1] = UInt8(Int64(bad[bad.size - 1]) ^ 1)
    var rejected = false
    try {
        let _ = aes128GcmDecrypt(key, iv, bad, Array<Byte>())
    } catch (e: Exception) {
        rejected = true
    }
    @Assert(rejected, true)
    // 换 key → 也必须拒绝
    let otherKey = hx("00000000000000000000000000000000")
    var rejected2 = false
    try {
        let _ = aes128GcmDecrypt(otherKey, iv, sealed, Array<Byte>())
    } catch (e: Exception) {
        rejected2 = true
    }
    @Assert(rejected2, true)
    // 标签长度不足（<16B）→ 直接拒绝，不静默当空
    var rejected3 = false
    try {
        let _ = aes128GcmDecrypt(key, iv, hx("00112233"), Array<Byte>())
    } catch (e: Exception) {
        rejected3 = true
    }
    @Assert(rejected3, true)
}
