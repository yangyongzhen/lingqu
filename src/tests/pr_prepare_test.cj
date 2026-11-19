package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.*

/*
 * 飞轮阶段 2（t2h:pr_prepare）单测：分支名、PR 正文、pitfalls 建议段、
 * 编排产物（tmp 下真实落盘）。只测纯函数 + 文件产物（D-009 允许的落档断言）。
 */

func prFixtureLesson(title: String, occurrences: Int64, archivedRef: String): LessonNote {
    let n = LessonNote()
    n.title = title
    n.symptom = "症状：" + title
    n.cause = "根因：" + title
    n.repro = "命令 xxx"
    n.fix = "修法：" + title
    n.occurrences = occurrences
    n.project = "pr-probe"
    n.archivedRef = archivedRef
    return n
}

@Test
public func testPrBranchNameSanitizes(): Unit {
    // git ref 安全集：字母数字 .-_ 保留，其余按**字节**换 -（"中文"= 6 字节 → 6 个 -）
    @Assert(prBranchName("habit-tree", 3), "flywheel/habit-tree-notes-3")
    @Assert(prBranchName("cc switch/中文", 2), "flywheel/cc-switch--------notes-2")
    // 边界：全非法字符 → 兜底 proj
    @Assert(prBranchName("///", 1), "flywheel/proj-notes-1")
}

@Test
public func testRenderPrBodyEvidenceChain(): Unit {
    let cands = ArrayList<LessonNote>()
    cands.add(prFixtureLesson("hvigor 00308018", 2, ""))
    let body = renderPrBody("pr-probe", cands)
    // 证据链六要素：标题 / 现象 / 根因 / 复现（含样本与次数）/ 修法
    @Assert(body.contains("### 1. hvigor 00308018"), true)
    @Assert(body.contains("- **现象**：症状：hvigor 00308018"), true)
    @Assert(body.contains("- **根因**：根因：hvigor 00308018"), true)
    @Assert(body.contains("样本：pr-probe，出现 2 次"), true)
    @Assert(body.contains("- **修法**：修法：hvigor 00308018"), true)
    // 提交前三问必须在（人只点提交 ≠ 不复核）
    @Assert(body.contains("提交前确认三问"), true)
}

@Test
public func testRenderPrBodyEmptyCandidates(): Unit {
    // 边界：没有候选要明说"没有"，不造空表
    let body = renderPrBody("pr-probe", ArrayList<LessonNote>())
    @Assert(body.contains("没有满足门槛的候选"), true)
}

@Test
public func testRenderPitfallsSuggestionThreeSegments(): Unit {
    // 四段 → 三段（现象 / 根因→修法 / 出处），带复核标记
    let cands = ArrayList<LessonNote>()
    cands.add(prFixtureLesson("坑 A", 3, ""))
    let sug = renderPitfallsSuggestion("pr-probe", cands)
    @Assert(sug.contains("<!-- lingqu pr_prepare 建议追加段"), true)
    @Assert(sug.contains("- **现象**：症状：坑 A"), true)
    @Assert(sug.contains("- **根因 → 修法**：根因：坑 A → 修法：坑 A"), true)
    @Assert(sug.contains("出现 3 次"), true)
}

@Test
public func testPreparePrWritesArtifactsAndDegrades(): Unit {
    // 编排：tmp 种子两条候选 → preparePr 产三份文件；无 token → degraded=true
    let dir = "/tmp/lingqu-pr-prepare-probe"
    let lq = dir + "/.lingqu"
    let notesPath = lq + "/notes/pr-probe.md"
    try {
        if (!exists(Path(lq + "/notes"))) {
            Directory.create(Path(lq + "/notes"))
        }
        // 两条四段齐全、出现 2 次、未入库的候选
        var text = "# 经验（pr-probe）\n\n"
        text += "## 坑 A\n\n- 症状：a\n- 根因：b\n- 复现：c\n- 修法：d\n- 出现 2 次（工程：pr-probe）\n\n"
        text += "## 坑 B\n\n- 症状：a2\n- 根因：b2\n- 复现：c2\n- 修法：d2\n- 出现 2 次（工程：pr-probe）\n"
        File.writeTo(notesPath, text.toArray())
    } catch (e: Exception) {
        return // /tmp 不可写则跳过，不造假
    }
    let r = preparePr(dir, "pr-probe", "") // 空 token → degraded
    @Assert(r.degraded, true)
    @Assert(r.canSubmit, false)
    @Assert(r.prepared, 2)
    @Assert(r.outError, "")
    // 三份产物真实落盘
    @Assert(exists(Path(r.bodyPath)), true)
    @Assert(exists(Path(r.suggestionPath)), true)
    @Assert(exists(Path(r.branchPath)), true)
    // PR 正文含两条候选
    let body = String.fromUtf8(File.readFrom(r.bodyPath))
    @Assert(body.contains("### 1. 坑 A"), true)
    @Assert(body.contains("### 2. 坑 B"), true)
    // 分支名带经验条数
    @Assert(r.branch, "flywheel/pr-probe-notes-2")
}

@Test
public func testPreparePrNoCandidatesNotesIt(): Unit {
    // 错误路径：没有候选 → 不产文件，note 明说（不假装准备好）
    let dir = "/tmp/lingqu-pr-prepare-empty"
    let r = preparePr(dir, "empty-probe", "token-x")
    @Assert(r.prepared, 0)
    @Assert(r.note.contains("没有满足门槛的候选"), true)
    @Assert(r.canSubmit, true) // token 在，但没有候选可提交
}

@Test
public func testPreparePrDedupesAndCapsPerRound(): Unit {
    // 阶段 3 护栏：同类去重（lessonKeyOf 相同只算一条）+ 单轮上限 5 截断并说明
    let dir = "/tmp/lingqu-pr-prepare-cap"
    let notesPath = dir + "/.lingqu/notes/pr-probe.md"
    try {
        if (!exists(Path(dir + "/.lingqu/notes"))) {
            Directory.create(Path(dir + "/.lingqu/notes"))
        }
        // 8 条候选（前两条完全同类：title+cause 相同 → 去重后 7 条 → 上限 5 截断）
        var text = "# 经验（pr-probe）\n\n"
        for (i in 0..8) {
            let same = i < 2
            let t = if (same) { "同类坑" } else { "坑 ${i}" }
            text += "## ${t}\n\n- 症状：s${i}\n- 根因：r${i}\n- 复现：c${i}\n- 修法：f${i}\n- 出现 2 次（工程：pr-probe）\n\n"
        }
        File.writeTo(notesPath, text.toArray())
    } catch (e: Exception) {
        return // /tmp 不可写则跳过，不造假
    }
    let r = preparePr(dir, "pr-probe", "")
    @Assert(r.prepared, MAX_CANDIDATES_PER_PR) // 去重 7 条 → 上限 5 截断
    @Assert(r.note.contains("单轮候选超上限"), true)
    // 落盘正文只含 5 条
    let body = String.fromUtf8(File.readFrom(r.bodyPath))
    @Assert(body.contains("### 5."), true)
    @Assert(!body.contains("### 6."), true)
    // 启动刷新语义说明在正文末尾（不热替换）
    @Assert(body.contains("下次启动"), true)
}

@Test
public func testSubmitAuthIsMultiSourceNotOneVar(): Unit {
    // 0.39.118：凭据**不再只认一个环境变量**——只认单个的话，"能不能发 PR"就成了个人自觉。
    let names = submitTokenEnvNamesOf()
    @Assert(names.contains("LINGQU_GITCODE_TOKEN"), true)
    @Assert(names.contains("GITCODE_TOKEN"), true)
    @Assert(names.contains("ATOMGIT_TOKEN"), true)
    @Expect(names.size >= 3, true)
    // 探测不到时必须**可操作**：给开启路径 + 明确"不授权也能自己提"（否则等于拿授权要挟用户）
    let hint = submitEnableHintOf()
    @Expect(hint.contains("LINGQU_GITCODE_TOKEN"), true)
    @Expect(hint.contains("atomgit"), true)
    @Expect(hint.contains("pr-body.md"), true)
    // 结果对象必须带这个字段（界面据此显示"怎么开"，而不是只剩一句"退化为本地产物"）
    let empty = PrPrepareResult()
    @Expect(empty.howToEnable, "")
}
