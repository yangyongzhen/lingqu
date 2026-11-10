package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.port.*

/*
 * 0.39.111 单测：指纹库 ↔ 技能 references 的**同源校验**（纯函数，D-009）。
 *
 * 为什么需要它：两条教训撞在一起——
 *   §4-164：只有"能被报错原文唯一认出"的串才进指纹表（所以指纹里那几个错误码都是唯一的）；
 *   §4-130："工具有能力、说明书没给 = agent 只能瞎摸"（所以要能查到处置）。
 * 合起来就是一条判据：**指纹库里出现的唯一错误码，技能文档里必须查得到**。
 * 这两处都是手写维护，靠"记得同步"必然漂移；所以做成纯函数 + 一条读真实文档的断言。
 */

/** 把技能 references 下所有 .md 正文拼起来（真实文档，不是样本） */
func refsTextOf(): String {
    let dir = "skills/t2h-ohos-port/references"
    var text = ""
    for (info in Directory.readFrom(Path(dir))) {
        if (info.isDirectory()) {
            continue
        }
        if (!info.name.endsWith(".md")) {
            continue
        }
        text += String.fromUtf8(File.readFrom(dir + "/" + info.name))
    }
    return text
}

/** 把缺口列表拼成一行，失败时能直接看出缺哪几个 */
func gapListTextOf(gaps: ArrayList<String>): String {
    var s = ""
    for (g in gaps) {
        s += (if (s.size == 0) { g } else { "；" + g })
    }
    return s
}

@Test
public func testIsUniqueErrorCodeOf(): Unit {
    @Assert(isUniqueErrorCodeOf("9568322"))
    @Assert(isUniqueErrorCodeOf("00303074"))
    @Assert(isUniqueErrorCodeOf("11111002"))
    // 短串不算：`-lgcc_eh` 里那种 4~6 位数字太容易误伤
    @Assert(!isUniqueErrorCodeOf("956832"))
    @Assert(!isUniqueErrorCodeOf("12345"))
    // 混了非数字就不算唯一错误码（这类串走技能/AGENTS，不进指纹表）
    @Assert(!isUniqueErrorCodeOf("95a8322"))
    @Assert(!isUniqueErrorCodeOf("00303242 xxx"))
    @Assert(!isUniqueErrorCodeOf(""))
    // 中文不是数字（按字节比，不会被误判）
    @Assert(!isUniqueErrorCodeOf("签名错误"))
}

@Test
public func testUniqueErrorCodesOfExtractsAndDedupes(): Unit {
    let text = "deploy 回 9568322；重装仍 9568322；另 hvigor 报 00303074，短号 123456 不算"
    let codes = uniqueErrorCodesOf(text)
    @Assert(codes.size == 2)
    @Assert(codes[0] == "9568322")
    @Assert(codes[1] == "00303074")
    // 空文本不给假值
    @Assert(uniqueErrorCodesOf("").size == 0)
    @Assert(uniqueErrorCodesOf("没有任何码").size == 0)
}

@Test
public func testUniqueErrorCodesOfHandlesBoundaries(): Unit {
    // 码紧贴中文、在行首行尾都要抽得出来（现场日志就是这样混排的）
    let codes = uniqueErrorCodesOf("中文9568322中文\n00303107\n尾部11111002")
    @Assert(codes.size == 3)
    @Assert(codes[0] == "9568322")
    @Assert(codes[2] == "11111002")
    // 8 位以上照样抽（00303074/11111002），不会因长度过长被截
    let longCodes = uniqueErrorCodesOf("1010610200")
    @Assert(longCodes.size == 1)
    @Assert(longCodes[0] == "1010610200")
}

@Test
public func testCodesMissingInDocsOf(): Unit {
    let doc = "### 5. `9568322 not trusted app source`"
    let missing = codesMissingInDocsOf("9568322 与 00303074", doc)
    @Assert(missing.size == 1)
    @Assert(missing[0] == "00303074")
    // 全都有 → 空（不报假红）
    @Assert(codesMissingInDocsOf("9568322", doc).size == 0)
    // 文本里没有码 → 空
    @Assert(codesMissingInDocsOf("没有码", doc).size == 0)
}

func fakeFpOf(id: String, marker: String, fix: String): Fingerprint {
    return Fingerprint(id, marker, "根因说明", fix, "", PK_GUIDE)
}

@Test
public func testFingerprintDocGapsOfReportsMissingCode(): Unit {
    let fps = ArrayList<Fingerprint>()
    fps.add(fakeFpOf("FP-901", "9568322", "处置：换 debug profile"))
    fps.add(fakeFpOf("FP-902", "11111002", "处置：sign --auto --newKeys"))
    // 文档只写了其中一条 → 另一条必须报缺口，且指名是哪条指纹
    let gaps = fingerprintDocGapsOf(fps, "### 5. 9568322 not trusted app source")
    @Expect(gaps.size, 1)
    @Expect(gaps[0].contains("FP-902"), true)
    @Expect(gaps[0].contains("11111002"), true)
}

@Test
public func testFingerprintDocGapsOfCleanAndDeduped(): Unit {
    let fps = ArrayList<Fingerprint>()
    fps.add(fakeFpOf("FP-901", "9568322", "同一条码在正文里再提一次 9568322"))
    // 同一码只算一次（正文重复提及不该变成两条缺口）
    let gaps = fingerprintDocGapsOf(fps, "文档里没有这个码")
    @Expect(gaps.size, 1)
    // 全都查得到 → 空
    @Assert(fingerprintDocGapsOf(fps, "文档写了 9568322").size == 0)
    // 没有码的指纹（走技能/AGENTS 那一档）不该被要求出现在文档里
    let markerOnly = ArrayList<Fingerprint>()
    markerOnly.add(fakeFpOf("FP-903", "unresolved import", "处置"))
    @Assert(fingerprintDocGapsOf(markerOnly, "").size == 0)
}

@Test
public func testRealReferencesCoverEveryFingerprintCode(): Unit {
    let refs = refsTextOf()
    // 文档读不到时不能静默"通过"——直接红
    @Expect(refs.size > 0, true)
    // 缺口列表当"文本 vs 空串"比：失败时 AssertEqual 会把缺哪几个码原样打出来
    @Assert(gapListTextOf(fingerprintDocGapsOf(fingerprintLibrary(), refs)), "")
}
