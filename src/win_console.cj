package lingqu

/**
 * 隐藏控制台（Windows）—— 0.39.40
 *
 * 现象（用户实测，问过三次）：「dos 的黑窗口现在还一闪一闪的弹出又消失」。
 *
 * 根因：本应用是 **GUI 子系统**（`--subsystem=windows`），进程**没有控制台**。
 * 此时任何一次 `std.process.executeWithOutput(...)`（hdc / cargo / node+hvigor / git / java / curl）
 * 都会让 Windows 给子进程**新配一个控制台窗口**——用户看到的就是一个个黑窗一闪。
 * 同理我们拉起的 cjh 走 `launchHidden`（DETACHED_PROCESS，子进程压根没有 console），
 * cjh 再拉 bash / find / lingqu-cli 时又各自新配一个 → 聊一个回合能闪十几次。
 *
 * 处置：**给本进程分一个隐藏控制台**（`AllocConsole` + `ShowWindow(SW_HIDE)`），
 * 之后所有子进程都继承它，于是"新配控制台窗口"这条路不再发生。
 * 这是**单点**修法——不需要去改几十处 spawn 调用点。
 *
 * 为什么不用 `CREATE_NO_WINDOW`：那只是"不显示窗口"，子进程仍持有一个隐藏 console、conhost 照挂；
 * 而我们要的正是"有一个看不见的 console 可继承"。真正的 `AllocConsole` + `SW_HIDE` 最直接。
 *
 * 失败不影响功能：`false` 只意味着"黑窗可能还会闪"，所有命令照常跑。
 */

@When[os == "Windows"]
foreign func AllocConsole(): Bool

@When[os == "Windows"]
foreign func GetConsoleWindow(): CPointer<Unit>

@When[os == "Windows"]
foreign func ShowWindow(hWnd: CPointer<Unit>, nCmdShow: Int32): Bool

/** 分配/隐藏一次；返回「现在本进程是否有一个（隐藏的）控制台」 */
@When[os == "Windows"]
public func ensureHiddenConsole(): Bool {
    unsafe {
        // 已经有控制台（命令行里跑 lingqu-cli 这种情形）：不动它，也别去隐藏用户自己的窗口
        let existing = GetConsoleWindow()
        if (!existing.isNull()) {
            return true
        }
        let ok = AllocConsole()
        let hwnd = GetConsoleWindow()
        if (hwnd.isNull()) {
            // 拿不到窗口句柄也算有控制台（极少数宿主不给），此时子进程已可继承
            return ok
        }
        // SW_HIDE = 0
        let _ = ShowWindow(hwnd, 0)
        return true
    }
}

@When[os != "Windows"]
public func ensureHiddenConsole(): Bool {
    return false
}
