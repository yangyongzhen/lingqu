package lingqu.tests

import std.collection.*
import std.env.*
import std.fs.*
import lingqu.compiler.*

/*
 * `t2h:sign` 签名体检单测（纯函数，D-009）。
 *
 * fixture：samples/evidence/ohos-profile.sample.p7b.txt —— 一份真实 debug profile 的**内嵌 JSON**，
 * 结构与真机可装的那份逐字段一致（type / bundle-info.bundle-name / development-certificate /
 * debug-info.device-ids …），**包名与设备 UDID 已换成合成值**（真 UDID 属设备标识，不进仓）。
 * 真实 .p7b 是 PKCS#7 二进制、内嵌 JSON 是明文，所以 extractProfileJson + 解析就能覆盖全部判定逻辑。
 */

func readSampleProfile(): String {
    return String.fromUtf8(File.readFrom("samples/evidence/ohos-profile.sample.p7b.txt"))
}

/** fixture 里第一个 device-ids（合成值，见上方说明） */
const UDID_IN_SAMPLE = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

@Test
public func testExtractProfileJsonFromBinaryLookalike(): Unit {
    // 模拟真实 .p7b：JSON 前后都有二进制垃圾
    let raw = "\u{0}\u{1}PADDING" + readSampleProfile() + "\u{2}\u{3}TRAILER"
    let json = extractProfileJson(raw)
    @Assert(json.startsWith("{"), true)
    @Assert(json.endsWith("}"), true)
    @Assert(json.contains("\"bundle-info\""), true)
    // 边界：没有花括号
    @Assert(extractProfileJson("no json here"), "")
    @Assert(extractProfileJson(""), "")
    // 关键：JSON 之后还有 `}`（证书二进制里的 0x7D）时，不能把尾部垃圾带进来
    let sample = readSampleProfile()
    @Assert(extractProfileJson(sample + "\u{7D}\u{7D}JUNK"), sample.trimAscii())
    // 字符串字面量里的花括号不参与配对
    @Assert(extractProfileJson("{\"a\":\"}\"}}"), "{\"a\":\"}\"}")
}

@Test
public func testParseProfileFields(): Unit {
    let p = parseOhosProfile(readSampleProfile(), "x.p7b")
    @Assert(p.parseError, "")
    @Assert(p.profileType, "debug")
    @Assert(p.bundleName, "com.example.demo")
    @Assert(p.deviceIds.size >= 2, true)
    // 关键判定：含本机 UDID 的允许，不认识的 UDID 不允许
    @Assert(p.allows(UDID_IN_SAMPLE), true)
    @Assert(p.allows("0000000000000000000000000000000000000000000000000000000000000000"), false)
    // 边界：空 JSON / 坏 JSON 不炸
    @Assert(parseOhosProfile("", "y.p7b").parseError != "", true)
    @Assert(parseOhosProfile("{not json", "z.p7b").parseError != "", true)
}

@Test
public func testReleaseProfileNeverAllows(): Unit {
    // release profile 即便 device-ids 里碰巧有该 UDID，也不该用于直装
    let releaseJson = "{\"type\":\"release\",\"bundle-info\":{\"bundle-name\":\"com.example.demo\"},\"debug-info\":{\"device-ids\":[\"${UDID_IN_SAMPLE}\"]}}"
    let p = parseOhosProfile(releaseJson, "r.p7b")
    @Assert(p.profileType, "release")
    @Assert(p.allows(UDID_IN_SAMPLE), false)
}

@Test
public func testMaterialSiblings(): Unit {
    let (p12, cer) = materialSiblingsOf("C:/x/default_ohos_abc=.p7b")
    @Assert(p12, "C:/x/default_ohos_abc=.p12")
    @Assert(cer, "C:/x/default_ohos_abc=.cer")
    // 不是 .p7b 结尾也不炸
    let (p12b, _) = materialSiblingsOf("weird")
    @Assert(p12b, "weird.p12")
}

@Test
public func testJudgeSignHappyPath(): Unit {
    let c = judgeSign(true, true, true, "debug", UDID_IN_SAMPLE, false)
    @Assert(c.ok, true)
    @Assert(c.nextStep.contains("hvigor"), true)
}

@Test
public func testJudgeSignFailureMatrix(): Unit {
    // ① 没 UDID（设备没连）
    let noUdid = judgeSign(true, true, true, "debug", "", false)
    @Assert(noUdid.ok, false)
    @Assert(noUdid.reason.contains("UDID"), true)
    // ② 工程没配 signingConfigs —— 有候选材料 vs 没有，下一步不同
    let noCfgWithCand = judgeSign(false, false, false, "", UDID_IN_SAMPLE, true)
    @Assert(noCfgWithCand.ok, false)
    @Assert(noCfgWithCand.nextStep.contains("抄回"), true)
    let noCfgNoCand = judgeSign(false, false, false, "", UDID_IN_SAMPLE, false)
    @Assert(noCfgNoCand.nextStep.contains("DevEco"), true)
    // ③ 材料文件不存在
    let missing = judgeSign(true, false, false, "debug", UDID_IN_SAMPLE, false)
    @Assert(missing.ok, false)
    @Assert(missing.reason.contains("不存在"), true)
    // ④ release profile
    let rel = judgeSign(true, true, false, "release", UDID_IN_SAMPLE, false)
    @Assert(rel.ok, false)
    @Assert(rel.reason.contains("9568322"), true)
    // ⑤ profile 不含本机 UDID
    let notReg = judgeSign(true, true, false, "debug", UDID_IN_SAMPLE, false)
    @Assert(notReg.ok, false)
    @Assert(notReg.reason.contains("device-ids"), true)
}

@Test
public func testPickProfilePrefersMatchingDevice(): Unit {
    let a = parseOhosProfile("{\"type\":\"debug\",\"bundle-info\":{\"bundle-name\":\"com.a\"},\"debug-info\":{\"device-ids\":[\"OTHER\"]}}", "a.p7b")
    let b = parseOhosProfile("{\"type\":\"debug\",\"bundle-info\":{\"bundle-name\":\"com.b\"},\"debug-info\":{\"device-ids\":[\"${UDID_IN_SAMPLE}\"]}}", "b.p7b")
    let cands = ArrayList<OhosProfile>()
    cands.add(a)
    cands.add(b)
    // 只看 UDID：应挑到 b
    match (pickProfile(cands, UDID_IN_SAMPLE, "")) {
        case Some(p) => @Assert(p.p7bPath, "b.p7b")
        case None => @Assert(true, false)
    }
    // 同时指定 bundle：包名不符 → 挑不到
    match (pickProfile(cands, UDID_IN_SAMPLE, "com.a")) {
        case Some(_) => @Assert(true, false)
        case None => ()
    }
}

@Test
public func testDiscoverProfilesOnRealConfigDir(): Unit {
    // 用本机真实目录（若存在）验证"扫得到、解析不炸"；不存在则跳过（不造假）
    let home = getVariable("USERPROFILE") ?? ""
    if (home == "") {
        return
    }
    let dir = "${home}/.ohos/config"
    if (!exists(Path(dir))) {
        return
    }
    let list = discoverProfiles(dir)
    @Assert(list.size > 0, true)
    var parsed = 0
    for (p in list) {
        if (p.parseError == "" && p.profileType != "") {
            parsed += 1
        }
    }
    @Assert(parsed > 0, true)
}

/* ---------- build-profile.json5（JSON5）解析 ---------- */

/**
 * 真实 build-profile.json5 的 signingConfigs 段（注释 + 尾逗号 + 单引号，json5 专有写法）。
 * 路径这里用正斜杠，避免多行字符串的转义语义干扰；反斜杠转义单独在下面那个用例里覆盖。
 */
const PROFILE_JSON5 = """
{
  // 应用级配置
  "app": {
    "signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "certpath": "C:/Users/me/.ohos/config/default_ohos_x.cer",
          "storePassword": "0000001B7D2E6E5C0D2E5F0E0A1B2C3D4E5F6071",
          "keyAlias": "debugKey",
          "keyPassword": "0000001B2E6E5C0D2E5F0E0A1B2C3D4E5F607182",
          "profile": "C:/Users/me/.ohos/config/default_ohos_x.p7b",
          "signAlg": "SHA256withECDSA",
          "storeFile": "C:/Users/me/.ohos/config/default_ohos_x.p12"
        }
      },
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
      },
    ],
  },
}
"""

@Test
public func testParseProjSigningHappyPath(): Unit {
    let s = parseProjSigning(PROFILE_JSON5)
    @Assert(s.hasSigningConfigs, true)
    @Assert(s.signingConfigName, "default")
    @Assert(s.certType, "HarmonyOS")
    @Assert(s.certPath, "C:/Users/me/.ohos/config/default_ohos_x.cer")
    @Assert(s.profilePath, "C:/Users/me/.ohos/config/default_ohos_x.p7b")
    @Assert(s.storeFile, "C:/Users/me/.ohos/config/default_ohos_x.p12")
}

@Test
public func testJson5EscapedWindowsPath(): Unit {
    // DevEco 在 Windows 上写的是双反斜杠；不还原就会拿 `D:\\oh\\...` 去 exists() → 永远"文件不存在"
    let text = "{\"material\":{\"certpath\":\"D:\\\\oh\\\\DevEcoStudio\\\\sdk\\\\a.cer\",\"profile\":\"D:\\\\oh\\\\b.p7b\"}}"
    let s = parseProjSigning(text)
    @Assert(s.certPath, "D:\\oh\\DevEcoStudio\\sdk\\a.cer")
    @Assert(s.profilePath, "D:\\oh\\b.p7b")
    // 其它常见转义
    @Assert(unescapeJson5("a\\nb"), "a\nb")
    @Assert(unescapeJson5("a\\\"b"), "a\"b")
    @Assert(unescapeJson5("a\\/b"), "a/b")
    // 末尾孤立反斜杠不越界
    @Assert(unescapeJson5("x\\"), "x\\")
}

@Test
public func testParseProjSigningEdgeCases(): Unit {
    // ① 空文本 / 没有签名段
    @Assert(parseProjSigning("").hasSigningConfigs, false)
    let bare = "{\"app\":{\"products\":[{\"name\":\"default\"}]}}"
    let b = parseProjSigning(bare)
    @Assert(b.hasSigningConfigs, false)
    @Assert(b.signingConfigName, "")
    @Assert(b.profilePath, "")
    // ② 空数组（cargo tauri ohos init 生成的原样）
    let empty = "{\"app\":{\"signingConfigs\":[],\"products\":[{\"signingConfig\":\"\"}]}}"
    let e = parseProjSigning(empty)
    @Assert(e.hasSigningConfigs, false)
    // ③ 单引号 + 无引号键（JSON5 允许）
    let loose = "{app: {signingConfigs: [{name: 'default', material: {profile: '/a/b.p7b', storeFile: '/a/b.p12', certpath: '/a/b.cer'}}]}}"
    let l = parseProjSigning(loose)
    @Assert(l.hasSigningConfigs, true)
    @Assert(l.profilePath, "/a/b.p7b")
    @Assert(l.storeFile, "/a/b.p12")
    @Assert(l.certPath, "/a/b.cer")
    // ④ 键不存在
    @Assert(json5ValueAfter("{ }", "signingConfig"), "")
    @Assert(json5ValueAfter("{\"a\":1}", "missing"), "")
}

/* ---------- hdc 输出解析 ---------- */

@Test
public func testParseUdidVariants(): Unit {    // 本机实测格式（前缀一行 + UDID 一行）
    let real = "udid of current device is :\n" + UDID_IN_SAMPLE + "\n"
    @Assert(parseUdid(real), UDID_IN_SAMPLE)
    // 前缀与值同行
    @Assert(parseUdid("udid of current device is : " + UDID_IN_SAMPLE), UDID_IN_SAMPLE)
    // 多个十六进制串时取最长（别把设备型号/序列号当 UDID）
    let noisy = "[Info] 3QC0124B20000048 OpenHarmony\nudid of current device is :\n" + UDID_IN_SAMPLE
    @Assert(parseUdid(noisy), UDID_IN_SAMPLE)
    // 报错输出 / 空输出 → ""
    @Assert(parseUdid("[Fail]ExecuteCommand need connect-key?"), "")
    @Assert(parseUdid(""), "")
    // 太短的十六进制串不算
    @Assert(parseUdid("deadbeef"), "")
}

/* ---------- 写回签名配置（apply） ---------- */

/** `cargo tauri ohos init` 生成的原样（signingConfigs 空、signingConfig 空串、尾逗号） */
const PROFILE_EMPTY = """
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "signingConfig": "",
        "compatibleSdkVersion": "5.0.0(12)",
        "runtimeOS": "HarmonyOS",
      },
    ],
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [{ "name": "default", "applyToProducts": ["default"] }],
    },
  ],
}
"""

/** 从已配好的工程里"搬"来的那块（口令是密文，原样搬运） */
func donorMaterial(): SigningMaterial {
    let m = SigningMaterial()
    m.name = "default"
    m.storeFile = "C:\\Users\\me\\.ohos\\config\\default_demo_abc=.p12"
    m.storePassword = "0000001B7D2E6E5C0D2E5F0E0A1B2C3D4E5F6071"
    m.keyPassword = "0000001B2E6E5C0D2E5F0E0A1B2C3D4E5F607182"
    m.profile = "C:\\Users\\me\\.ohos\\config\\default_demo_abc=.p7b"
    m.certpath = "C:\\Users\\me\\.ohos\\config\\default_demo_abc=.cer"
    return m
}

@Test
public func testApplySigningConfigHappyPath(): Unit {
    let m = donorMaterial()
    @Assert(m.complete(), true)
    let (out, err) = applySigningConfig(PROFILE_EMPTY, m)
    @Assert(err, "")
    // 结果必须能被自己的解析器读回来（这是闭环断言：写得进去 = 读得出来）
    let parsed = parseProjSigning(out)
    @Assert(parsed.hasSigningConfigs, true)
    @Assert(parsed.signingConfigName, "default")
    @Assert(parsed.certType, "HarmonyOS")
    // 写进去的路径必须是转义后的，解析回来等于原值（Windows 双反斜杠往返）
    @Assert(parsed.storeFile, m.storeFile)
    @Assert(parsed.profilePath, m.profile)
    @Assert(parsed.certPath, m.certpath)
    // 口令密文与签名算法 / 别名也要原样带过去
    @Assert(json5ValueAfter(out, "storePassword"), m.storePassword)
    @Assert(json5ValueAfter(out, "keyPassword"), m.keyPassword)
    @Assert(json5ValueAfter(out, "keyAlias"), "debugKey")
    @Assert(json5ValueAfter(out, "signAlg"), "SHA256withECDSA")
    // 其余结构（modules / products 的其它字段）不能被破坏
    @Assert(out.contains("\"compatibleSdkVersion\": \"5.0.0(12)\""), true)
    @Assert(out.contains("\"applyToProducts\""), true)
    @Assert(out.contains("\"modules\""), true)
    // 不能出现重复闭合（实测踩到 `]]`：注入时把原数组的 `]` 留下了，json5 直接语法错误）
    @Assert(bracketBalance(out), 0)
    @Assert(out.contains("]]"), false)
}

/** 方括号/花括号配平检查（0 = 平衡；>0 少闭合，<0 多闭合） */
func bracketBalance(text: String): Int64 {
    let bytes = text.toArray()
    var square: Int64 = 0
    var curly: Int64 = 0
    var inStr = false
    var esc = false
    for (b in bytes) {
        if (inStr) {
            if (esc) {
                esc = false
            } else if (b == 92) {
                esc = true
            } else if (b == 34) {
                inStr = false
            }
            continue
        }
        if (b == 34) {
            inStr = true
        } else if (b == 91) {
            square++
        } else if (b == 93) {
            square--
        } else if (b == 123) {
            curly++
        } else if (b == 125) {
            curly--
        }
    }
    return square + curly
}

@Test
public func testApplySigningConfigRefusesOverwrite(): Unit {
    // ① 已有非空 signingConfigs → 不覆盖（幂等的另一面：二次 apply 必须报错而不是叠加）
    let m = donorMaterial()
    let (out, err) = applySigningConfig(PROFILE_EMPTY, m)
    @Assert(err, "")
    let (out2, err2) = applySigningConfig(out, m)
    @Assert(out2, "")
    @Assert(err2.contains("已经有非空"), true)
    // ② 材料不全（没有口令密文）→ 拒绝（否则写进去 hvigor 也解不开）
    let partial = SigningMaterial()
    partial.storeFile = "a.p12"
    partial.profile = "a.p7b"
    partial.certpath = "a.cer"
    @Assert(partial.complete(), false)
    let (_, err3) = applySigningConfig(PROFILE_EMPTY, partial)
    @Assert(err3.contains("材料不完整"), true)
    // ③ 结构里根本没有 signingConfigs → 明确报错，不乱插
    let (_, err4) = applySigningConfig("{\"app\":{\"products\":[{\"name\":\"default\"}]}}", m)
    @Assert(err4.contains("找不到 signingConfigs"), true)
    // ④ 空文本
    let (_, err5) = applySigningConfig("", m)
    @Assert(err5 != "", true)
}

@Test
public func testPointProductSigningConfigBranches(): Unit {
    // 空串 → 填上
    let (a, e1) = pointProductSigningConfig("{\"products\":[{\"signingConfig\":\"\"}]}", "default")
    @Assert(e1, "")
    @Assert(a.contains("\"signingConfig\":\"default\""), true)
    // 已指向目标 → 原样返回（不改动，保证幂等）
    let same = "{\"products\":[{\"signingConfig\":\"default\"}]}"
    let (b, e2) = pointProductSigningConfig(same, "default")
    @Assert(e2, "")
    @Assert(b, same)
    // 指向别的名字 → 不猜，报错
    let (_, e3) = pointProductSigningConfig("{\"products\":[{\"signingConfig\":\"releaseCfg\"}]}", "default")
    @Assert(e3.contains("releaseCfg"), true)
    // 没有该字段 / 空名字
    let (_, e4) = pointProductSigningConfig("{\"products\":[{\"name\":\"default\"}]}", "default")
    @Assert(e4.contains("找不到"), true)
    let (_, e5) = pointProductSigningConfig(same, "")
    @Assert(e5 != "", true)
}

@Test
public func testMaterialIdentityAndEscaping(): Unit {
    // 同一份材料：目录不同、分隔符不同，但文件名相同 → 视为同一套
    @Assert(sameMaterialFile("C:\\Users\\me\\.ohos\\config\\x=.p12", "D:/other/x=.p12"), true)
    @Assert(sameMaterialFile("C:\\a\\X=.P12", "C:\\a\\x=.p12"), true)   // 大小写不敏感
    @Assert(sameMaterialFile("C:\\a\\one.p12", "C:\\a\\two.p12"), false)
    @Assert(sameMaterialFile("", "C:\\a\\one.p12"), false)
    // 取文件名（两种分隔符）
    @Assert(fileNameOf("C:\\a\\b\\c.p7b"), "c.p7b")
    @Assert(fileNameOf("/a/b/c.p7b"), "c.p7b")
    @Assert(fileNameOf("c.p7b"), "c.p7b")
    // 转义：反斜杠翻倍、引号加反斜杠
    @Assert(json5EscapeOf("C:\\a\\b"), "C:\\\\a\\\\b")
    @Assert(json5EscapeOf("say \"hi\""), "say \\\"hi\\\"")
    // 往返：转义后再还原，等于原值
    @Assert(unescapeJson5(json5EscapeOf("D:\\oh\\x.cer")), "D:\\oh\\x.cer")
}

