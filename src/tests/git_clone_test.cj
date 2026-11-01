package lingqu.tests

import std.collection.*
import lingqu.*

/*
 * 「从 Git 克隆拿工程」的纯函数单测（0.39.25）。
 *
 * 守的三条（都是"错了不会报错、只会悄悄做错事"的类型）：
 *   ① 地址白名单——`-` 开头的会被 git 当选项（`--upload-pack=…` 参数注入就是这么来的）；
 *   ② 仓库目录名——要能从 https / ssh / scp 三种形态里取出干净目录名；
 *   ③ 冲突不覆盖——同名目录要能算出 `-2`/`-3`，绝不能往用户既有目录里 clone。
 */

@Test
public func testGitUrlWhitelist(): Unit {
    // 允许的三种形态
    @Assert(gitUrlRejectReason("https://atomgit.com/qq8864/lingqu.git"), "")
    @Assert(gitUrlRejectReason("http://10.0.0.2/x/y.git"), "")
    @Assert(gitUrlRejectReason("ssh://git@host:2222/org/repo.git"), "")
    @Assert(gitUrlRejectReason("git://host/org/repo.git"), "")
    @Assert(gitUrlRejectReason("file:///E:/test/rust/habit-tree"), "")
    @Assert(gitUrlRejectReason("git@atomgit.com:qq8864/lingqu.git"), "")
    // 拒绝：空 / 以 - 开头（会被 git 当选项）/ 带空白 / 其他协议
    @Assert(gitUrlRejectReason(""), "地址为空")
    @Assert(gitUrlRejectReason("   "), "地址为空")
    @Assert(gitUrlRejectReason("--upload-pack=calc").contains("- 开头"), true)
    @Assert(gitUrlRejectReason("-oProxyCommand=x").contains("- 开头"), true)
    @Assert(gitUrlRejectReason("https://a b/c.git").contains("空格"), true)
    @Assert(gitUrlRejectReason("https://a/b\nrm -rf /").contains("换行"), true)
    @Assert(gitUrlRejectReason("javascript:alert(1)").contains("只认"), true)
    @Assert(gitUrlRejectReason("ftp://host/x.git").contains("只认"), true)
    // `a:b` 这种冒号形态不能被当成 scp（没有 @）
    @Assert(gitUrlRejectReason("C:/x/y").contains("只认"), true)
}

@Test
public func testRepoDirName(): Unit {
    @Assert(repoDirNameOf("https://atomgit.com/qq8864/lingqu.git"), "lingqu")
    @Assert(repoDirNameOf("https://atomgit.com/qq8864/lingqu"), "lingqu")
    @Assert(repoDirNameOf("https://atomgit.com/qq8864/lingqu.git/"), "lingqu")
    @Assert(repoDirNameOf("git@atomgit.com:qq8864/habit-tree.git"), "habit-tree")
    @Assert(repoDirNameOf("ssh://git@host:2222/org/repo.git"), "repo")
    @Assert(repoDirNameOf("file:///E:/test/rust/habit-tree"), "habit-tree")
    // 反斜杠也认（Windows 上粘贴本地路径）
    @Assert(repoDirNameOf("E:\\test\\rust\\habit-tree"), "habit-tree")
    // 非法字符被净化成 `_`（Windows 目录名不能有 : ? * " < > |）
    @Assert(repoDirNameOf("https://h/x/a:b*c?d"), "a_b_c_d")
    // 取不到名字时兜底
    @Assert(repoDirNameOf("https://host/"), "host")
    @Assert(repoDirNameOf(""), "repo")
    @Assert(repoDirNameOf(".."), "repo")
}

@Test
public func testCloneDirNameCollisionNaming(): Unit {
    // 第 1 次用原名，之后 -2、-3……（同名目录绝不覆盖）
    @Assert(cloneDirNameAt("habit-tree", 1), "habit-tree")
    @Assert(cloneDirNameAt("habit-tree", 2), "habit-tree-2")
    @Assert(cloneDirNameAt("habit-tree", 7), "habit-tree-7")
    @Assert(cloneDirNameAt("habit-tree", 0), "habit-tree")
}

@Test
public func testTauriProjectHints(): Unit {
    // 只有"像不像"的提示，不拦人
    @Assert(tauriProjectHints(true, true, true).contains("有 src-tauri"), true)
    @Assert(tauriProjectHints(false, true, true).contains("monorepo"), true)
    @Assert(tauriProjectHints(false, true, false).contains("不像完整"), true)
    @Assert(tauriProjectHints(false, false, false).contains("没发现"), true)
}

@Test
public func testWorkspaceRootDefault(): Unit {
    // 没设 LINGQU_WORKSPACES 时要有兜底（不能返回空串，否则 clone 会落到 CWD）
    let root = workspaceRootDir()
    @Assert(root != "", true)
    @Assert(root.contains("lingqu-workspaces"), true)
}

@Test
public func testGitCloneRejectsBadUrlBeforeSpawningGit(): Unit {
    // 纯逻辑层就该挡掉：返回 error 且不产生 target（避免"先跑了 git 再说"）
    let r = gitCloneProject("--upload-pack=calc", "", 1)
    @Assert(r.ok, false)
    @Assert(r.error.contains("地址不可用"), true)
    @Assert(r.target, "")
    // 空地址同理
    let r2 = gitCloneProject("", "", 1)
    @Assert(r2.ok, false)
    @Assert(r2.error != "", true)
}
