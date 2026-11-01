package lingqu.tests

import std.collection.*
import lingqu.*

/*
 * 5 样本矩阵"读哪个工程的落档 + 去哪找样本"的纯函数单测（0.39.29）。
 *
 * 背景（实测踩到的）：矩阵读档原先一律是相对当前工作目录的 `.lingqu/...`，
 * 于是读到的是**本仓**的旧档 —— m3u8dl-tauri 明明跑到可用率 100%，矩阵里却写「未跑 / 25%」。
 * 守的三条：
 *   ① 落档相对路径的拼法（步骤 + 工程名）只有一处构造点；
 *   ② 候选根目录的解析顺序与去重（显式根 → 工作区 → 家目录默认）不能被改乱；
 *   ③ 分隔符要认 `|` / `;` / 逗号 / 换行，去空白去重，空串不能变成"一个空根"。
 */

@Test
public func testSampleLqRel(): Unit {
    // 7 个步骤的落档路径必须与各命令写入时同名（改一处就是整片"未跑"）
    @Assert(sampleLqRel("scan", "habit-tree"), "scan/habit-tree.json")
    @Assert(sampleLqRel("deps", "habit-tree"), "deps/habit-tree.json")
    @Assert(sampleLqRel("build", "habit-tree"), "build/habit-tree.json")
    @Assert(sampleLqRel("hap", "habit-tree"), "hap/habit-tree.json")
    @Assert(sampleLqRel("sign", "habit-tree"), "sign/habit-tree.json")
    @Assert(sampleLqRel("deploy", "habit-tree"), "deploy/habit-tree.json")
    @Assert(sampleLqRel("verify", "habit-tree"), "verify/habit-tree.json")
    // 落档路径是 `.lingqu` **之下**的相对路径：不能带 `.lingqu/` 前缀
    // （带了再喂 resolveLqPath 会变成 `.lingqu/.lingqu/...`，见 AGENTS §4-75）
    @Assert(sampleLqRel("scan", "x").startsWith(".lingqu"), false)
}

@Test
public func testSplitRootList(): Unit {
    // 四种分隔符都认
    let a = splitRootList("E:/a|E:/b;E:/c,E:/d")
    @Assert(a.size, 4)
    @Assert(a[0], "E:/a")
    @Assert(a[3], "E:/d")
    // 换行 + 首尾空白 + 重复项
    let b = splitRootList("  E:/x \n E:/y \r\n E:/x ")
    @Assert(b.size, 2)
    @Assert(b[0], "E:/x")
    @Assert(b[1], "E:/y")
    // 空串/只有分隔符 → 空列表（不能造出一个空根，否则会被当成"根目录 = 当前目录"）
    @Assert(splitRootList("").size, 0)
    @Assert(splitRootList(" || ; ,, ").size, 0)
}

@Test
public func testSampleRootsOrder(): Unit {
    // 显式根最优先，工作区根其次，家目录默认工作区兜底
    let r = sampleRootsOf("E:/samples", "E:/ws", "C:/Users/me")
    @Assert(r.size, 3)
    @Assert(r[0], "E:/samples")
    @Assert(r[1], "E:/ws")
    @Assert(r[2].contains("lingqu-workspaces"), true)

    // 显式根与工作区重复 → 只留一份（顺序按先出现的）
    let r2 = sampleRootsOf("E:/ws", "E:/ws", "C:/Users/me")
    @Assert(r2.size, 2)
    @Assert(r2[0], "E:/ws")

    // 没有任何环境变量时，至少还有家目录默认工作区；homeDir 为空则整列为空
    let r3 = sampleRootsOf("", "", "/home/u")
    @Assert(r3.size, 1)
    @Assert(sampleRootsOf("", "", "").size, 0)
}
