package lingqu.tests

import lingqu.compiler.*

/*
 * hvigor `AesGcmKit` 口令密文配套件的单测（0.39.13）。
 *
 * PBKDF2 的期望值由本机 Node（DevEco 自带，走 OpenSSL）独立算出，与 RFC 公开向量一致；
 * 也就是说这里测的是"我们与 OpenSSL/hvigor 算得一样"，不是"我们自己和自己一样"。
 */

@Test
public func testPbkdf2PublicVectors(): Unit {
    let pwd = "password".toArray()
    let salt = "salt".toArray()
    // c=1 / dkLen=32
    @Assert(toHexLower(pbkdf2HmacSha256(pwd, salt, 1, 32)),
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    // c=2
    @Assert(toHexLower(pbkdf2HmacSha256(pwd, salt, 2, 32)),
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    // c=4096
    @Assert(toHexLower(pbkdf2HmacSha256(pwd, salt, 4096, 32)),
        "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    // AesGcmKit 用的正是 c=10000 / dkLen=16
    @Assert(toHexLower(pbkdf2HmacSha256(pwd, salt, PBKDF2_ITERATIONS, AES_GCM_KEY_LEN)),
        "5ec02b91a4b59c6f59dd5fbe4ca649ec")
}

@Test
public func testHmacSha256Vector(): Unit {
    // RFC 4231 风格的标准向量：key="key"，data="The quick brown fox jumps over the lazy dog"
    let mac = hmacSha256("key".toArray(), "The quick brown fox jumps over the lazy dog".toArray())
    @Assert(toHexLower(mac), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    @Assert(mac.size, 32)
}

@Test
public func testLossyUtf8ReplacesInvalidSequences(): Unit {
    // 纯 ASCII 原样
    @Assert(toHexLower(lossyUtf8Bytes("abc".toArray())), "616263")
    // 合法多字节（中文"灵渠"）原样保留
    @Assert(toHexLower(lossyUtf8Bytes("灵渠".toArray())), toHexLower("灵渠".toArray()))
    // 非法首字节 0xFF → 一个 U+FFFD
    @Assert(toHexLower(lossyUtf8Bytes([0xFF])), "efbfbd")
    // 截断的多字节序列（E4 B8 缺第三个字节）→ U+FFFD（先替换首字节，余下继续按非法处理）
    let truncated = lossyUtf8Bytes([0xE4, 0xB8])
    @Assert(truncated.size >= 3, true)
    @Assert(toHexLower(truncated).startsWith("efbfbd"), true)
    // 代理区（ED A0 80 = U+D800）必须判非法
    @Assert(toHexLower(lossyUtf8Bytes([0xED, 0xA0, 0x80])).startsWith("efbfbd"), true)
    // 过长编码（C0 80）必须判非法
    @Assert(toHexLower(lossyUtf8Bytes([0xC0, 0x80])).startsWith("efbfbd"), true)
    // 空输入
    @Assert(lossyUtf8Bytes(Array<Byte>()).size, 0)
}

@Test
public func testPasswordEncryptDecryptRoundTrip(): Unit {
    // workKey 随便给 16 字节：这里只验"同一 workKey 下加解密自洽 + IV 每次不同"
    let workKey = fromHexLower("00112233445566778899aabbccddeeff").getOrThrow()
    let (hex1, e1) = encryptPasswordHex(workKey, "P@ssw0rd-abc")
    @Assert(e1, "")
    @Assert(hex1.size > 4 + 12 + 16, true)          // hex 长度 > (len|iv|tag) 的两倍
    let (plain, e2) = decryptPasswordHex(workKey, hex1)
    @Assert(e2, "")
    @Assert(plain, "P@ssw0rd-abc")
    // 同一口令两次加密：IV 随机 → 密文不同（别写相等断言，DevEco 同款行为）
    let (hex2, _) = encryptPasswordHex(workKey, "P@ssw0rd-abc")
    @Assert(hex1 == hex2, false)
    // 换 workKey 解密必须失败（GCM 认证）
    let other = fromHexLower("ffeeddccbbaa99887766554433221100").getOrThrow()
    let (_, e3) = decryptPasswordHex(other, hex1)
    @Assert(e3 != "", true)
    // 非法 hex / 载荷损坏也要给原因，不静默
    let (_, e4) = decryptPasswordHex(workKey, "zz")
    @Assert(e4 != "", true)
    // workKey 长度不对：加密直接拒绝
    let (bad, e5) = encryptPasswordHex(Array<Byte>(15, repeat: 0), "x")
    @Assert(bad, "")
    @Assert(e5 != "", true)
}
