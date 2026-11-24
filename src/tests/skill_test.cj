package lingqu.tests

import lingqu.*
import std.collection.*

/*
 * AI 接入第 1 步（把 t2h-ohos-port 技能装进 cjh）的纯函数单测。
 *
 * 守的口径：
 *   ① 技能正文里的 `references/x.md` 相对链接，装到 `~/.cjh/skills` 后必须改写成**绝对路径**——
 *      否则 agent 按 cwd 相对路径去读，一定读不到（它的 cwd 是用户工程，不是技能目录）；
 *   ② 状态判定用**内容哈希**，不看时间戳（checkout/复制会把时间戳改掉，但内容没变）；
 *   ③ `enabled_skills` 的白名单语义不能想当然：**空 = 全部启用**，非空才是白名单；
 *      提示必须说清"要不要手动加"，且不能建议乱加（会关掉别的技能）。
 */

@Test
public func testSkillPaths(): Unit {
    // 路径都要落在 <home>/.cjh/skills 下（cjh 的固定约定）
    let home = "C:\\Users\\u"
    let dir = cjhSkillsDirOf(home)
    @Assert(dir.contains(".cjh"), true)
    @Assert(dir.endsWith("skills"), true)
    let target = skillTargetPathOf(home)
    @Assert(target.endsWith("t2h-ohos-port.md"), true)
    @Assert(target.startsWith(dir), true)
    // references 放隐藏子目录：cjh 只扫 skills/*.md，嵌套目录不会被当成第二个技能
    let refs = skillRefDirOf(home)
    @Assert(refs.contains(".t2h-ohos-port"), true)
    @Assert(refs.endsWith("references"), true)
    // home 为空 → 空串（调用方据此如实报错，而不是拼出 "\\.cjh\\skills" 这种相对路径）
    @Assert(cjhSkillsDirOf(""), "")
    @Assert(skillTargetPathOf(""), "")
    @Assert(skillRefDirOf(""), "")
    @Assert(cjhSettingsPathOf(""), "")
}

@Test
public func testRewriteSkillLinks(): Unit {
    let refDir = "C:\\Users\\u\\.cjh\\skills\\.t2h-ohos-port\\references"
    // Markdown 链接形态（最常被 agent 读到的）
    let md = "见 [签名](references/signing.md) 与 [坑](references/pitfalls.md)"
    let out = rewriteSkillLinks(md, refDir)
    @Assert(out.contains("(" + refDir + "/signing.md)"), true)
    @Assert(out.contains("(" + refDir + "/pitfalls.md)"), true)
    // 裸提形态（正文里"见 references/xxx"也要改）
    let bare = "手工装配见 references/toolchain.md 那一节"
    let out2 = rewriteSkillLinks(bare, refDir)
    @Assert(out2.contains(" " + refDir + "/toolchain.md"), true)
    // 别的文本不受影响；refDir 为空时原样返回（不制造半截路径）
    let plain = "没有任何引用的正文"
    @Assert(rewriteSkillLinks(plain, refDir), plain)
    @Assert(rewriteSkillLinks(md, ""), md)
    // 幂等性：已改写的正文再改一次不会叠出两层绝对路径
    let twice = rewriteSkillLinks(out, refDir)
    @Assert(twice, out)
}

@Test
public func testSkillState(): Unit {
    // 没装
    @Assert(skillStateOf(false, "", "abc"), "missing")
    @Assert(skillStateOf(true, "", "abc"), "missing")
    // 已装且一致
    @Assert(skillStateOf(true, "abc", "abc"), "installed")
    // 装了但内容变了（仓库更新过 / 手工改过）
    @Assert(skillStateOf(true, "abc", "def"), "outdated")
    // 来源读不到时不能判"已是最新"——那是自欺
    @Assert(skillStateOf(true, "abc", ""), "outdated")
}

@Test
public func testSkillEnableNote(): Unit {
    // 白名单为空 = 全部启用（cjh 语义），不需要改配置
    let note = skillEnableNoteOf(ArrayList<String>())
    @Assert(note.contains("全部启用"), true)
    @Assert(note.contains("不需要改"), true)

    // 白名单已含本技能
    let wl = ArrayList<String>()
    wl.add("t2h-ohos-port")
    wl.add("other")
    @Assert(skillEnableNoteOf(wl).contains("已包含"), true)

    // 白名单非空但不含本技能 → 要提示手动加，且把现有名单列出来
    let wl2 = ArrayList<String>()
    wl2.add("cangjie")
    let note2 = skillEnableNoteOf(wl2)
    @Assert(note2.contains("白名单非空但不含"), true)
    @Assert(note2.contains("cangjie"), true)
    // 提示里不能劝人"直接覆盖白名单"（那会关掉别的技能）——只说要加进去
    @Assert(note2.contains("加进去"), true)
}

@Test
public func testSkillSourceCandidates(): Unit {
    // 逐级向上：base 自己 + 父 + 祖父…，每层都拼 skills/t2h-ohos-port
    let cands = skillSourceCandidates("E:\\repo\\sub", 3)
    @Assert(cands.size >= 2, true)
    @Assert(cands[0].startsWith("E:\\repo\\sub"), true)
    @Assert(cands[0].endsWith("skills" + cjhPathSep() + "t2h-ohos-port"), true)
    @Assert(cands[1].startsWith("E:\\repo"), true)
    @Assert(cands[1].contains("sub"), false)
    // 末尾分隔符不影响结果
    let withSep = skillSourceCandidates("E:\\repo\\sub\\", 3)
    @Assert(withSep[0], cands[0])
    // 空 base / levels<=0 → 无候选（别造出 "\skills\t2h-ohos-port" 这种相对路径）
    @Assert(skillSourceCandidates("", 6).size, 0)
    @Assert(skillSourceCandidates("E:\\repo", 0).size, 0)
}

@Test
public func testSkillHashOfBytesIsStable(): Unit {
    // 同内容同哈希；不同内容不同哈希；大小写敏感（内容就是内容）
    let a = skillHashOfBytes("---\nname: x\n---\n正文".toArray())
    let b = skillHashOfBytes("---\nname: x\n---\n正文".toArray())
    let c = skillHashOfBytes("---\nname: x\n---\n正文2".toArray())
    @Assert(a, b)
    @Assert(a == c, false)
    @Assert(a.size, 64)     // SHA256 十六进制 = 64 字符
}

/*
 * 0.39.144：**references 陈旧也要能被抓到**。
 *
 * 现场：`~/.cjh/skills/.t2h-ohos-port/references/native-ui-bridge.md` 停在 11-21（9,576 B），
 * 仓里 11-23 已到 15,818 B，而 `t2h:skill status` 报 `installed`——因为旧判据只比 SKILL.md 正文。
 * 后果不是"少一份文档"，而是 agent 顺着技能里的**绝对链接**读到**旧版**，新口径（同名 IPC shim、
 * 路径 API 不信返回值、目录打不开）一条都看不到。
 */

@Test
public func testSkillRefsDrift(): Unit {
    let src = ArrayList<SkillRefHash>()
    src.add(SkillRefHash("a.md", "h1"))
    src.add(SkillRefHash("b.md", "h2"))
    src.add(SkillRefHash("c.md", "h3"))

    // 一致 → 空表
    let same = ArrayList<SkillRefHash>()
    same.add(SkillRefHash("a.md", "h1"))
    same.add(SkillRefHash("b.md", "h2"))
    same.add(SkillRefHash("c.md", "h3"))
    @Assert(skillRefsDriftOf(src, same).size, 0)

    // 内容不同（b）+ 缺失（c），明细要能点名到文件、并说清是哪种
    let inst = ArrayList<SkillRefHash>()
    inst.add(SkillRefHash("a.md", "h1"))
    inst.add(SkillRefHash("b.md", "OLD"))
    let drift = skillRefsDriftOf(src, inst)
    @Assert(drift.size, 2)
    @Assert(drift[0].contains("b.md"), true)
    @Assert(drift[0].contains("内容不同"), true)
    @Assert(drift[1].contains("c.md"), true)
    @Assert(drift[1].contains("缺失"), true)

    // 安装件多出来的**不报**：installSkill 刻意不删旧文件，且没有 SKILL.md 索引指向它们
    let extra = ArrayList<SkillRefHash>()
    extra.add(SkillRefHash("a.md", "h1"))
    extra.add(SkillRefHash("b.md", "h2"))
    extra.add(SkillRefHash("c.md", "h3"))
    extra.add(SkillRefHash("old-removed.md", "hx"))
    @Assert(skillRefsDriftOf(src, extra).size, 0)

    // 一份都没装 → 全是缺失
    @Assert(skillRefsDriftOf(src, ArrayList<SkillRefHash>()).size, 3)
    // 来源为空（只剩内嵌正文）→ 无漂移：无法比对时不许凭空报，改由 refNote 如实说"没比"
    @Assert(skillRefsDriftOf(ArrayList<SkillRefHash>(), inst).size, 0)

    // 文案要点出份数与"重跑安装"；无漂移回空串（调用方据此判"没漂移"）
    let text = skillRefsDriftTextOf(drift)
    @Assert(text.contains("2 份"), true)
    @Assert(text.contains("重跑一次安装"), true)
    @Assert(skillRefsDriftTextOf(ArrayList<String>()), "")
}

@Test
public func testSkillStateWithRefs(): Unit {
    // 正文一致 + references 陈旧 = outdated（正是 0.39.144 那个假"已安装"）
    @Assert(skillStateWithRefsOf("installed", 1), "outdated")
    @Assert(skillStateWithRefsOf("installed", 0), "installed")
    // 没装就是没装——别用"内容不一致"盖住"从来没装过"
    @Assert(skillStateWithRefsOf("missing", 3), "missing")
    @Assert(skillStateWithRefsOf("outdated", 0), "outdated")
}

@Test
public func testSkillRefPointerCore(): Unit {
    // 已装进 cjh → 用那份的绝对路径（SKILL.md 里的链接也指向它，人机读到同一份）
    let p1 = skillRefPointerCoreOf("C:\\Users\\u\\.cjh\\skills\\.t2h-ohos-port\\references\\x.md", "",
        "t2h-ohos-port", "x")
    @Assert(p1.contains("C:\\Users\\u\\.cjh\\skills"), true)
    @Assert(p1.contains("先跑"), false)

    // 只有来源目录 → 也给绝对路径，并说明本机还没装进 cjh
    let p2 = skillRefPointerCoreOf("", "E:\\repo\\skills\\t2h-ohos-port\\references\\x.md", "t2h-ohos-port", "x")
    @Assert(p2.contains("E:\\repo\\skills"), true)
    @Assert(p2.contains("没装进 cjh"), true)

    // 两边都没有 → 只给技能名 + 安装命令，**绝不产出相对路径**
    // （agent 的 bash cwd 是目标工程，`skills/t2h-ohos-port/...` 在那边不存在，AGENTS §4-70）
    let p3 = skillRefPointerCoreOf("", "", "t2h-ohos-port", "native-ui-bridge")
    @Assert(p3.contains("t2h-ohos-port"), true)
    @Assert(p3.contains("native-ui-bridge"), true)
    @Assert(p3.contains("skill --action install"), true)
    @Assert(p3.startsWith("`skills/"), false)
}

@Test
public func testSkillRefPointerForReal(): Unit {
    // 真实调用（读本机与仓库）：结果要么是绝对路径，要么是"未装 + 安装命令"，
    // 绝不许再出现任务书里那句相对路径 `skills/t2h-ohos-port/references/...`
    let p = skillRefPointerFor("native-ui-bridge")
    @Assert(p.contains("native-ui-bridge"), true)
    @Assert(p.startsWith("`skills/"), false)
    @Assert(p.contains("references") || p.contains("未装"), true)
}
