package lingqu.tests

import lingqu.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 工具链体检（t2h:env）的判定口径（0.39.95）。
 *
 * 起因是用户实测的一句诘问：「这些是不是准确？llvm-mingw 跟移植不相关吧，不相干的不需要展示」。
 * 本机 hdc 与 llvm-mingw 都装着，面板却双双报「缺失」：
 *   - hdc 用裸 DEVECO_SDK_HOME（过期值，指着已删除的旧 DevEco）拼路径；
 *   - llvm-mingw 只认写死的一条 `C:\tool\llvm-mingw\bin`，而实际装在带版本号的目录、且只在 PATH 里。
 * 这里把「能不能真跑到」的判定收成纯函数钉住，别让它再退化成「某个目录里有没有文件」。
 */

// ---------------- pathDirsOf：PATH 变量 → 目录列表 ----------------

@Test
public func testPathDirsSplitsOnWindowsSeparatorKeepingDriveColon(): Unit {
    // Windows 路径里的 `:` 属于盘符，只有 `;` 才是分隔符
    let dirs = pathDirsOf("C:\\tool\\llvm-mingw-x\\bin;D:\\Program Files\\Rust\\bin", ";")
    @Expect(dirs.size, 2)
    @Expect(dirs[0], "C:\\tool\\llvm-mingw-x\\bin")
    @Expect(dirs[1], "D:\\Program Files\\Rust\\bin")
}

@Test
public func testPathDirsSplitsOnPosixSeparator(): Unit {
    let dirs = pathDirsOf("/usr/local/bin:/usr/bin", ":")
    @Expect(dirs.size, 2)
    @Expect(dirs[1], "/usr/bin")
}

@Test
public func testPathDirsDropsEmptyAndDuplicates(): Unit {
    // PATH 里常见空段（末尾分号）与重复项，都不能变成「候选目录」污染判定
    let dirs = pathDirsOf(" ; C:\\tool\\bin ; ; C:\\tool\\bin ;", ";")
    @Expect(dirs.size, 1)
    @Expect(dirs[0], "C:\\tool\\bin")
}

@Test
public func testPathDirsEmptyInputGivesNone(): Unit {
    @Expect(pathDirsOf("", ";").size, 0)
}

// ---------------- llvmMingwRootsOf：安装根去重 ----------------

@Test
public func testLlvmMingwRootsDedupesAndDropsEmpty(): Unit {
    let roots = llvmMingwRootsOf("C:\\tool", "", "C:\\tool")
    @Expect(roots.size, 1)
    @Expect(roots[0], "C:\\tool")
}

@Test
public func testLlvmMingwRootsKeepsOrder(): Unit {
    let roots = llvmMingwRootsOf("C:\\tool", "C:\\Program Files", "C:\\Program Files (x86)")
    @Expect(roots.size, 3)
    @Expect(roots[1], "C:\\Program Files")
}

// ---------------- isLlvmMingwDirName：发行目录名判定 ----------------

@Test
public func testLlvmMingwDirNameAcceptsVersionedRelease(): Unit {
    // 本机就是这种带日期与 ABI 后缀的目录名
    @Assert(isLlvmMingwDirName("llvm-mingw-20260324-ucrt-x86_64"))
    @Assert(isLlvmMingwDirName("llvm-mingw"))
}

@Test
public func testLlvmMingwDirNameRejectsUnrelated(): Unit {
    // 同一层目录里还躺着 terminal / build 之类，不能被当成 llvm-mingw
    @Assert(!isLlvmMingwDirName("terminal-1.25.1322.0"))
    @Assert(!isLlvmMingwDirName("llvm"))
    @Assert(!isLlvmMingwDirName(""))
}

// ---------------- addCheckScoped：「就绪 / 缺失」的口径 ----------------

@Test
public func testCheckFoundIsOkWithoutHint(): Unit {
    var arr = JsonArray()
    addCheckScoped(arr, "hdc", "hdc 设备桥", "真机部署", "C:\\sdk\\hdc.exe", "设 DEVECO_HOME")
    let o = arr[0].asObject()
    @Expect(o.get("ok").getOrThrow().asBool().getValue(), true)
    // 找到了就不该再挂「怎么办」的提示（提示只在缺失时出现，否则又是一条谎报）
    @Expect(o.get("hint").getOrThrow().asString().getValue(), "")
    @Expect(o.get("scope").getOrThrow().asString().getValue(), "真机部署")
    @Expect(o.get("path").getOrThrow().asString().getValue(), "C:\\sdk\\hdc.exe")
}

@Test
public func testCheckMissingCarriesHint(): Unit {
    var arr = JsonArray()
    addCheckScoped(arr, "llvm-mingw", "llvm-mingw（宿主 C 编译器）", "仅 Windows 主机构建", "", "加进 PATH")
    let o = arr[0].asObject()
    @Expect(o.get("ok").getOrThrow().asBool().getValue(), false)
    @Expect(o.get("hint").getOrThrow().asString().getValue(), "加进 PATH")
}
