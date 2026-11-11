package lingqu.tests

import lingqu.compiler.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 0.39.114 单测：材料配套性预检 `judgeMaterialKeys`（证书 / .p12 / profile 是不是"一套"）。
 *
 * 为什么必须先判：这条链上"签 HAP 用的证书 ≠ profile 绑的证书"**没有任何环节会报错**，
 * 只有 hvigor 报 11111002 或装机回 9568322 才知道（§4-165，实测栽过）。
 * 两种成因处置完全不同——"本地没材料"要补文件，"钥匙不配"要 `--newKeys`——
 * 所以判据必须分开，不能一律说"重下证书"（拿"重下"去治"钥匙不配"是白跑一轮）。
 */

let FAKE_BODY: String = "MIIBfakeBodyABCDEFGH0123456789"

let FAKE_OTHER_BODY: String = "MIIBotherBodyZYXWVUT9876543210"

/** 造一条只含一张证书的 .cer（真文件是多张的链，这里只要能比就行） */
func cerOf(body: String): String {
    return "-----BEGIN CERTIFICATE-----\n" + body + "\n-----END CERTIFICATE-----\n"
}

@Test
public func testMaterialKeysReadableProfileMissingCertIsNotBlocked(): Unit {
    // profile 里读不出证书：不拦（证书格式一变不该让整条链全红，与 ensureCerMatchesProfile 同口径）
    let v = judgeMaterialKeys(true, cerOf(FAKE_BODY), "")
    @Assert(v.ok, true)
    @Assert(v.blocked, false)
    @Assert(v.reason.size > 0, true)
    @Expect(v.nextStep, "")   // 不拦就不用给下一步
}

@Test
public func testMaterialKeysNoLocalCerIsBlockedWithFillMaterialStep(): Unit {
    let v = judgeMaterialKeys(false, "", FAKE_BODY)
    @Assert(v.ok, false)
    @Assert(v.blocked, true)
    // "没材料"给的是补材料的路（--auto 会下载证书并写回 signingConfigs）
    @Assert(v.nextStep.size > 0, true)
    @Assert(v.reason.size > 0, true)
}

@Test
public func testMaterialKeysEmptyCerTextIsTreatedAsMissing(): Unit {
    // 文件在但读出来是空：等于没有（别拿"文件存在"当"材料可用"，§4-122 同族）
    let v = judgeMaterialKeys(true, "   \n\t ", FAKE_BODY)
    @Assert(v.ok, false)
    @Assert(v.blocked, true)
}

@Test
public func testMaterialKeysSameCertPasses(): Unit {
    // .cer 里的正文与 profile 绑的正文一致（比较口径是"去空白后的正文"）
    let v = judgeMaterialKeys(true, cerOf(FAKE_BODY), FAKE_BODY)
    @Assert(v.ok, true)
    @Assert(v.blocked, false)
    @Expect(v.nextStep, "")
}

@Test
public func testMaterialKeysDifferentCertIsBlockedAndPointsToNewKeys(): Unit {
    // 链里是别的一张：必然 11111002；重下 .cer 治不好"钥匙不配"，必须点明 --newKeys
    let v = judgeMaterialKeys(true, cerOf(FAKE_OTHER_BODY), FAKE_BODY)
    @Assert(v.ok, false)
    @Assert(v.blocked, true)
    @Assert(v.nextStep.indexOf("--newKeys").isSome(), true)
    @Assert(v.reason.indexOf(SIGN_CERT_MISMATCH_CODE).isSome(), true)
    // 装机那一侧的码也要写在结论里：两个码是同一件事的两端，agent 才会对上"装不上"这个现象
    @Assert(v.reason.indexOf(SIGN_UNTRUSTED_INSTALL_CODE).isSome(), true)
}

@Test
public func testMaterialKeysChainWithMultipleCertsMatches(): Unit {
    // 真 .cer 是链（多张）：只要其中一张对上就算配套
    let chain = cerOf(FAKE_OTHER_BODY) + cerOf(FAKE_BODY)
    let v = judgeMaterialKeys(true, chain, FAKE_BODY)
    @Assert(v.ok, true)
}

@Test
public func testMaterialCheckToJsonShape(): Unit {
    // 落档/回投都读这四个键，形状变了消费方就拿不到结论
    let v = judgeMaterialKeys(true, cerOf(FAKE_OTHER_BODY), FAKE_BODY)
    let j = v.toJson()
    @Assert(j.get("ok").isSome(), true)
    @Assert(j.get("blocked").isSome(), true)
    @Assert(j.get("reason").isSome(), true)
    @Assert(j.get("nextStep").isSome(), true)
}
