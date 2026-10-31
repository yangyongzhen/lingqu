package lingqu.tests

import lingqu.*

/*
 * 注入给 agent 的工程上下文（AGENTS.md 受管区块）——**路径必须是真的**（0.38.2）。
 *
 * 背景：0.37.2 实测 agent 照着区块里的路径去找落档，结果 `.lingqu/` 里只有任务书本身
 * （那时落档还在灵渠应用目录）。0.38.x 把落档迁进工程后，这段文案才成立；
 * 这里钉住三件事：① 说清"本工程根"；② 落档表覆盖 port/report/migrate；
 * ③ 给了工具绝对路径就必须用绝对路径，不许再写 `lingqu-cli`。
 */

@Test
public func testAgentContextBodySaysProjectRoot(): Unit {
    let b = agentContextBody("habit-tree", "E:/test/rust/habit-tree")
    @Assert(b.contains("本工程根"), true)
    @Assert(b.contains("不是灵渠应用目录"), true)
    // 落档表要覆盖新增的几类
    @Assert(b.contains(".lingqu/port/habit-tree/decisions.json"), true)
    @Assert(b.contains(".lingqu/migrate/habit-tree.md"), true)
    @Assert(b.contains(".lingqu/<步骤>/habit-tree.log"), true)
    // 断点板在老位置，必须说明白（否则 agent 会去工程里找 tasks.json）
    @Assert(b.contains("灵渠应用目录") && b.contains("tasks.json"), true)
}

@Test
public func testAgentContextBodyUsesAbsoluteCliWhenGiven(): Unit {
    let cli = "C:/lingqu/bin/lingqu-cli.exe"
    let b = agentContextBodyWith("habit-tree", "E:/test/rust/habit-tree", cli)
    @Assert(b.contains(cli), true)
    @Assert(b.contains(cli + " resume --path ."), true)
    // 给了绝对路径就不该再出现裸命令名（否则 agent 可能照抄那条跑不通的）
    @Assert(b.contains("lingqu-cli resume"), false)
    // 没给的时候退回裸命令名 + 明确提示要问应用要路径
    let b2 = agentContextBodyWith("x", "E:/x", "")
    @Assert(b2.contains("lingqu-cli resume"), true)
    @Assert(b2.contains("不在 PATH"), true)
}
