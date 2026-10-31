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
