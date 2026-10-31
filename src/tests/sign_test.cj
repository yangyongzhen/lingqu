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

// ============================================================
// 0.39.9：包名门槛（hvigor 00303074）
// ============================================================
//
// 复现的缺陷（先红后绿的用例）：工程包名 com.atomgit.m3u8dl_tauri、本机只有别的包名的材料时，
// 0.39.8 的工具说"机器上已有匹配本机 UDID 的材料 → 抄回来即可"。照着做，hvigor 在
// default@SignHap 报 00303074（bundleName 与 SigningConfigs 不一致）——建议本身就是错的。
// 现在：候选包名不等于工程包名时，结论必须明确"用不了"，并把正解（DevEco 自动签名）写进下一步。

@Test
public func testBundleMatchesExactOnly(): Unit {
    @Assert(bundleMatches("com.a.b", "com.a.b"), true)
    @Assert(bundleMatches(" com.a.b ", "com.a.b"), true)      // 容忍两侧空白（读 json5 会带）
    @Assert(bundleMatches("com.a.b", "com.a.c"), false)
    @Assert(bundleMatches("com.a.b", "COM.A.B"), false)       // bundleName 区分大小写
    @Assert(bundleMatches("", "com.a.b"), false)              // 空包名不算匹配（别把"不知道"当"匹配"）
    @Assert(bundleMatches("com.a.b", ""), false)
    @Assert(bundleMatches("", ""), false)
}

@Test
public func testProfileBundleCensusListsBundlesAndDeviceState(): Unit {
    let a = parseOhosProfile("{\"type\":\"debug\",\"bundle-info\":{\"bundle-name\":\"com.x\"},\"debug-info\":{\"device-ids\":[\"${UDID_IN_SAMPLE}\"]}}", "a.p7b")
    let b = parseOhosProfile("{\"type\":\"debug\",\"bundle-info\":{\"bundle-name\":\"com.y\"},\"debug-info\":{\"device-ids\":[\"OTHER\"]}}", "b.p7b")
    let bad = OhosProfile()
    bad.p7bPath = "c.p7b"
    bad.parseError = "读不到"
    let cands = ArrayList<OhosProfile>()
    cands.add(a)
    cands.add(b)
    cands.add(bad)
    let census = profileBundleCensus(cands, UDID_IN_SAMPLE)
    // 解析失败的份不列（列出来只会误导）
    @Assert(census.contains("com.x"), true)
    @Assert(census.contains("com.y"), true)
    @Assert(census.contains("含本机"), true)
    @Assert(census.contains("不含本机"), true)
    // 空候选 / 全部解析失败 → 空串
    @Assert(profileBundleCensus(ArrayList<OhosProfile>(), UDID_IN_SAMPLE), "")
}

@Test
public func testWritebackRefusesOtherBundle(): Unit {
    // 现场复刻：材料文件缺（m3u8dl-tauri 的真实状态）+ 候选是别的包名
    let base = judgeSign(true, false, false, "debug", UDID_IN_SAMPLE, true)
    let refined = judgeSignForWriteback(base, "com.atomgit.m3u8dl_tauri", "com.yang.testcj",
        "com.yang.testcj(27台/含本机)、com.jiujiang.habit_tree(26台/含本机)")
    @Assert(refined.ok, false)
    @Assert(refined.bundleMatch, false)
    // 必须点名 hvigor 的错误码与真正原因（否则人还会去查路径/口令）
    @Assert(refined.nextStep.contains("00303074"), true)
    @Assert(refined.reason.contains("包名"), true)
    @Assert(refined.nextStep.contains("com.atomgit.m3u8dl_tauri"), true)   // 缺的是哪个包名
    @Assert(refined.nextStep.contains("com.jiujiang.habit_tree"), true)    // 本机有哪几个包名
    @Assert(refined.nextStep.contains("DevEco"), true)                     // 正解
    // 原始判定不被改写（副本语义）
    @Assert(base.bundleMatch, true)
    @Assert(base.nextStep.contains("00303074"), false)
}

@Test
public func testWritebackKeepsAdviceWhenBundleMatches(): Unit {
    // 包名对得上：结论原样保留（"抄回来即可"在这时是对的）
    let base = judgeSign(false, false, false, "", UDID_IN_SAMPLE, true)
    let refined = judgeSignForWriteback(base, "com.jiujiang.habit_tree", "com.jiujiang.habit_tree", "")
    @Assert(refined.bundleMatch, true)
    @Assert(refined.nextStep, base.nextStep)
    // 已经能装（ok=true）的工程：即使候选串对不上也不改文案——它用的是自己那份材料
    let good = judgeSign(true, true, true, "debug", UDID_IN_SAMPLE, false)
    let kept = judgeSignForWriteback(good, "com.jiujiang.habit_tree", "", "")
    @Assert(kept.ok, true)
    @Assert(kept.reason, good.reason)
    @Assert(kept.nextStep, good.nextStep)
}

@Test
public func testWritebackSilentWhenNoCandidate(): Unit {
    // 没有候选材料（设备离线 → udid="" → pickProfile 挑不到）：不叠"包名不一致"那句，
    // 「拿不到设备 UDID」才是真正要处理的事（实测踩到：设备离线时被误报成包名问题）
    let base = judgeSign(true, true, true, "debug", "", false)
    let refined = judgeSignForWriteback(base, "com.atomgit.m3u8dl_tauri", "",
        "com.yang.testcj(27台/UDID未知)")
    @Assert(refined.bundleMatch, false)
    @Assert(refined.nextStep, base.nextStep)
    @Assert(refined.reason, base.reason)
    // UDID 未知时清单里不写"不含本机"（会让人误以为是设备没注册进 profile）
    @Assert(refined.reason.contains("不含本机"), false)
}

@Test
public func testWritebackWithoutProjectBundle(): Unit {
    // 读不到工程 bundleName（AppScope 缺失）：**不能编"包名不一致"**（0.39.11 实测：
    // atomMqtt 就是这样被写成"工程包名 （读不到） 与候选材料包名不一致"的，读着像真结论）
    // 只提示先确认 AppScope，原判定的下一步保持不变。
    let base = judgeSign(false, false, false, "", UDID_IN_SAMPLE, true)
    let refined = judgeSignForWriteback(base, "", "com.yang.testcj", "")
    @Assert(refined.bundleMatch, false)
    @Assert(refined.reason.contains("无法判断候选材料是否匹配"), true)
    @Assert(refined.reason.contains("与候选材料包名不一致"), false)
    @Assert(refined.nextStep, base.nextStep)
}

// ============================================================
// 0.39.11：装配前的签名预检（judgeSignPreflight）
// ============================================================
//
// 复现的浪费：m3u8dl-tauri 的 signingConfigs 指向别的包名的材料 → `t2h:hap` 先跑分钟级的
// hvigor，跑完只换来一句 00303074。预检把这条判定挪到 hvigor 之前（秒级）。
// 纪律：**只在必然失败时拦**——没配签名（能产 unsigned HAP）与"材料缺文件但 unsigned 仍可能产出"
// 都不拦，只留提示。

@Test
public func testPreflightAllowsUnsignedBuild(): Unit {
    // 没配 signingConfigs：不拦（不签名也能产 HAP，闸门会如实报"未签名"）
    let p = judgeSignPreflight(false, false, "com.a.b", "")
    @Assert(p.block, false)
    @Assert(p.reason, "")
    @Assert(p.projectBundle, "com.a.b")
}

@Test
public func testPreflightWarnsOnMissingMaterialWithoutBlocking(): Unit {
    // 配了但材料文件不存在 → 不拦，提示 00303107（unsigned HAP 仍可能产出）
    let p = judgeSignPreflight(true, false, "com.a.b", "")
    @Assert(p.block, false)
    @Assert(p.reason.contains("00303107"), true)
    @Assert(p.reason.contains("签名体检"), true)
}

@Test
public func testPreflightBlocksOnBundleMismatch(): Unit {
    // 现场复刻：工程 com.atomgit.m3u8dl_tauri，材料签给 com.yang.testcj
    let p = judgeSignPreflight(true, true, "com.atomgit.m3u8dl_tauri", "com.yang.testcj")
    @Assert(p.block, true)
    @Assert(p.reason.contains("00303074"), true)
    @Assert(p.reason.contains("com.atomgit.m3u8dl_tauri"), true)
    @Assert(p.reason.contains("com.yang.testcj"), true)
    @Assert(p.reason.contains("DevEco"), true)         // 正解必须在
    // 反过来同样要拦（材料签给别的包名，方向无关）
    @Assert(judgeSignPreflight(true, true, "com.x", "com.y").block, true)
}

@Test
public func testPreflightPassesWhenBundleMatches(): Unit {
    // 包名一致（habit-tree 的真机现场）：不拦、无提示
    let p = judgeSignPreflight(true, true, "com.jiujiang.habit_tree", "com.jiujiang.habit_tree")
    @Assert(p.block, false)
    @Assert(p.reason, "")
    // 读不到工程包名 → 不拦（把判定交回 hvigor，别自己造假阴性）
    let q = judgeSignPreflight(true, true, "", "com.yang.testcj")
    @Assert(q.block, false)
    @Assert(q.reason.contains("bundleName"), true)
}