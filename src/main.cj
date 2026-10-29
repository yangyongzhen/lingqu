package lingqu

import cjTauri.*
import cjTauri.plugins.log.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*

/*
 * 灵渠迁移台 · 业务装配点（RFC-002 §4.1）
 *
 * 分工：
 *   - 本文件：环境体检（doctor）+ 命令注册 + 生命周期接线
 *   - cjh_host.cj：cjh 引擎托管（发现 / 健康检查 / 拉起 / 收尾 / 部署），移植自 ai-chat
 *
 * 平台知识为零：窗口、页面、资产、能力目录都由清单 cj-tauri.toml 决定，
 * 桌面 launcher 与鸿蒙 entry 各自覆盖——同一份业务代码编出两端。
 */

// ============================================================
// 小工具
// ============================================================

/** 拼路径：自动处理分隔符，避免 base 末尾已有分隔符时出现双分隔 */
public func joinPath(base: String, name: String): String {
    if (base.size == 0) {
        return name
    }
    let last = base[base.size - 1]
    if (last == 92u8 || last == 47u8) {
        return base + name
    }
    return base + "\\" + name
}

/** 读环境变量，空值按缺省处理 */
func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) =>
            if (v.size > 0) {
                return v
            }
            return fallback
        case None => return fallback
    }
}

/** 从候选路径里取第一个存在的（体检用：同一工具在不同机器上位置不同） */
public func firstExisting(cands: Array<String>): String {
    for (p in cands) {
        if (p.size > 0 && exists(p)) {
            return p
        }
    }
    return ""
}

/** 体检项：ok 由「找到与否」决定，缺了给一句「缺了就怎么办」 */
func addCheck(arr: JsonArray, id: String, label: String, found: String, hint: String): Unit {
    var o = JsonObject()
    o.put("id", JsonString(id))
    o.put("label", JsonString(label))
    let ok = found.size > 0
    o.put("ok", JsonBool(ok))
    o.put("path", JsonString(found))
    var hintText = ""
    if (!ok) {
        hintText = hint
    }
    o.put("hint", JsonString(hintText))
    arr.add(o)
}

// ============================================================
// ① 环境体检（t2h:env）
// ============================================================

/**
 * 把迁移所需的工具链一次性体检出来。
 * 判定口径：路径存在 = 就绪。版本号等「能跑起来才知道」的检查留给后续 t2h:doctor。
 */
public class EnvCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        let home = envOr("USERPROFILE", "")
        let ndk = envOr("NATIVE_OHOS_SDK", "")
        let deveco = envOr("DEVECO_HOME", "")
        let sdkRoot = envOr("DEVECO_SDK_HOME", "")

        var arr = JsonArray()

        addCheck(arr, "rustc", "Rust 工具链（rustc / cargo）",
            firstExisting([
                joinPath(home, ".cargo\\bin\\rustc.exe"),
                "C:\\Program Files\\Rust\\bin\\rustc.exe"
            ]),
            "装 rustup 后应在 %USERPROFILE%\\.cargo\\bin；迁移要靠它交叉编译 .so")

        addCheck(arr, "llvm-mingw", "llvm-mingw（Windows 链接前提）",
            firstExisting([
                "C:\\tool\\llvm-mingw\\bin\\x86_64-w64-mingw32-clang.exe"
            ]),
            "gnullvm 工具链不自带 C 编译器；缺它会报 linker x86_64-w64-mingw32-clang not found")

        var ndkClang = ""
        if (ndk.size > 0) {
            ndkClang = firstExisting([joinPath(ndk, "llvm\\bin\\clang.exe")])
        }
        addCheck(arr, "ohos-ndk", "OHOS NDK（clang / sysroot）", ndkClang,
            "设 NATIVE_OHOS_SDK 指向 SDK 的 native 目录（DevEco 下载 SDK 后就有）")

        addCheck(arr, "deveco", "DevEco Studio",
            firstExisting([deveco]),
            "设 DEVECO_HOME 指向 DevEco Studio 安装目录（打包 HAP 需要 hvigor / ohpm）")

        addCheck(arr, "hvigor", "hvigor 构建器",
            firstExisting([
                joinPath(deveco, "tools\\hvigor\\bin\\hvigorw.bat"),
                joinPath(deveco, "tools\\hvigor\\bin\\hvigorw")
            ]),
            "它随 DevEco 一起装；缺了说明 DEVECO_HOME 没指对")

        addCheck(arr, "ohpm", "ohpm 包管理器",
            firstExisting([
                joinPath(deveco, "tools\\ohpm\\bin\\ohpm.bat"),
                joinPath(deveco, "tools\\ohpm\\bin\\ohpm")
            ]),
            "它随 DevEco 一起装；HAP 装配前要装 oh 依赖")

        addCheck(arr, "hdc", "hdc 设备桥",
            firstExisting([
                joinPath(sdkRoot, "HarmonyOS-NEXT-DB6\\openharmony\\toolchains\\hdc.exe"),
                joinPath(sdkRoot, "default\\openharmony\\toolchains\\hdc.exe")
            ]),
            "它随 SDK 走；部署到鸿蒙 PC 真机靠它")

        // cjh 复用 cjh_host 的解析（env → 已部署 → 仓内 vendor，vendor 还要过 SHA256）
        addCheck(arr, "cjh", "AI 引擎 cjh（内置）", cjhBinPath(),
            "把 cjh.exe 放到 vendor/cjh/win-x64/ 或用 LINGQU_CJH 指向它；缺了 AI 面板不可用（其余功能照常）")

        var res = JsonObject()
        res.put("items", arr)
        res.put("cjhPort", JsonInt(cjhPort()))
        return res
    }
}

// ============================================================
// ② 退出（t2h:quit）：先收 cjh，再退窗口
// ============================================================

/**
 * 前端主动退应用。顺序有意为之：**先收我们自己拉起的 cjh，再退窗口**——
 * 反过来的话窗口一关事件循环就返回，收尾只能靠守护线程兜底（那条路也留着，见 startLifecycleWaiter）。
 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        eprintln("[lingqu] 前端请求退出")
        shutdownCjh()
        this.app.quit()
        return JsonBool(true)
    }
}

// ============================================================
// ③ 生命周期接线
// ============================================================

/**
 * 退出收尾的守护线程。
 *
 * 为什么需要它：新形态 AppSpec 没有 onExit 钩子，业务拿不到「run 之后」那一行——
 * ai-chat 是 `app.run(html)` 之后直接调 shutdownCjh()，这里改成用 waitForExit() 等窗口全退出。
 *
 * 两个前提：① wire 在 run 之前执行，此刻窗口还没登记，得先等主窗出现，
 * 否则 allWindowsExited() 立刻为真、收尾会在拉起 cjh 之前就跑完（等于没收）；
 * ② 只收自己拉起的（shutdownCjh 内部按 gCjhOwned 判定）。
 */
func startLifecycleWaiter(app: TauriApp): Unit {
    spawn {
        var spins: Int64 = 0
        var registered = false
        while (!registered && spins < 300) {
            match (app.hostOf("main")) {
                case Some(_) => registered = true
                case None =>
                    sleep(Duration.millisecond * 100)
                    spins += 1
            }
        }
        if (!registered) {
            eprintln("[lingqu] 主窗 30s 内没登记——退出收尾不挂载（cjh 不会被自动收回）")
            return
        }
        app.waitForExit()
        eprintln("[lingqu] 窗口已全部退出，开始收尾")
        // 收尾跑几轮：自动拉起引擎在后台线程里，可能与"用户秒关窗口"抢跑——
        // 单次 shutdownCjh 有可能在 gCjhOwned 变 true 之前就跑完，等于没收
        var i: Int64 = 0
        while (i < 5) {
            shutdownCjh()
            sleep(Duration.millisecond * 200)
            i += 1
        }
    }
}

// ============================================================
// 业务装配点
// ============================================================

/**
 * 装配：命令注册 + 引擎接线。
 * 新命令记得同步 assets/capabilities/default.json，否则前端拿到 command not allowed。
 */
public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("lingqu", 1280, 840))
        // 日志落盘：GUI 产物双击没控制台，报障时一个文件看全
        .plugin(LogPlugin())
        .wire({ app =>
            // 日志落盘：GUI 产物双击没控制台，报障时一个文件看全（C 桥 + 仓颉 + 页面 log:write）
            let _ = app.setLogToDefaultFile("lingqu")

            app.register("t2h:env", EnvCommand())
            app.register("t2h:quit", QuitCommand(app))

            // cjh 三条运维命令（status 纯读 / start 按路径 / deploy 校验+部署+拉起）
            let cjhCmds = CjhCommands()
            app.register("t2h:cjh_status", cjhCmds)
            app.register("t2h:cjh_start", cjhCmds)
            app.register("t2h:cjh_deploy", cjhCmds)

            // 退出收尾（窗口关掉也生效）
            startLifecycleWaiter(app)

            // 引擎随窗口一起起来：放后台线程，别让 cjh 的 10s 就绪等待挡住窗口出现
            spawn {
                let ok = ensureCjhWeb()
                if (ok) {
                    eprintln("[lingqu] AI 引擎就绪：127.0.0.1:${cjhPort()}")
                }
            }
        })
}
