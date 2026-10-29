package lingqu

import cjTauri.*
import std.env.*
import std.fs.*
import std.net.*
import stdx.encoding.json.*

/*
 * 灵渠迁移台 · 业务装配点（RFC-002 §4.1）
 *
 * 本文件只负责「灵渠」这个应用自己的业务：
 *   ① 环境体检（doctor）：把「这台机器还缺什么」算清楚，一次说清；
 *   ② cjh 引擎接入：探测 / 拉起内置的 cjh（AI 引擎），对应 ai-chat 的 cjh_host 思路；
 *   ③ 迁移相关命令的注册点（后续 scan/port/build/deploy 在这里挂）。
 *
 * 平台知识为零：窗口、页面、资产、能力目录都由清单 cj-tauri.toml 决定，
 * 桌面 launcher 与鸿蒙 entry 各自覆盖——同一份业务代码编出两端。
 */

// ============================================================
// 常量：开发期默认值（生产由配置/环境变量覆盖）
// ============================================================

/** 内置 cjh 的仓内位置（相对工程根；vendor 那份与本机开发期的兜底路径同优先级链） */
let VENDOR_CJH_REL_WIN = "vendor\\cjh\\win-x64\\cjh.exe"

/** 本机开发期的兜底路径（最后才用；换机器请用 vendor 或 LINGQU_CJH） */
let DEFAULT_CJH_PATH = "E:\\test\\rust\\test1\\cjh\\cjh.exe"

/** cjh web 服务端口：与 cjh / ai-chat 的既有约定一致，复用优先 */
let CJH_PORT: Int64 = 8765

/** cjh web 服务监听地址：只绑本机回环，不对外暴露 */
let CJH_BIND = "127.0.0.1"

// ============================================================
// 小工具
// ============================================================

/** 拼路径：自动处理分隔符，避免 base 末尾已有分隔符时出现双分隔 */
func joinPath(base: String, name: String): String {
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
func firstExisting(cands: Array<String>): String {
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

/**
 * cjh 可执行文件的实际路径，按优先级找：
 *   ① LINGQU_CJH 环境变量（部署后可覆盖）
 *   ② 仓内 vendor/cjh/win-x64/cjh.exe（工程根为工作目录时）
 *   ③ 同上，工程根上跳一层（在 targets/desktop 下启动时）
 *   ④ 本机开发期兜底路径
 * 全都没有返回空串 —— 上层据此报告「引擎缺失」，而不是猜一个路径去执行。
 */
func cjhPath(): String {
    let fromEnv = envOr("LINGQU_CJH", "")
    return firstExisting([
        fromEnv,
        VENDOR_CJH_REL_WIN,
        "..\\" + VENDOR_CJH_REL_WIN,
        DEFAULT_CJH_PATH
    ])
}

/** 端口探测：能建立 TCP 连接就算「在跑」（不依赖 cjh 的 HTTP 实现细节） */
func probePort(host: String, port: Int64): Bool {
    try {
        let sock = TcpSocket(host, UInt16(port))
        sock.connect(timeout: Duration.millisecond * 800)
        sock.close()
        return true
    } catch (e: Exception) {
        return false
    }
}

/** 取 arg 里的字符串字段（前端 invoke 传进来的都在这） */
func argString(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

// ============================================================
// ① 环境体检（t2h:env）
// ============================================================

/**
 * 把迁移所需的工具链一次性体检出来。
 * 判定口径：路径存在 = 就绪。版本号等「能跑起来才知道」的检查留给后续
 * t2h:doctor（会真的执行 --version），骨架阶段先保证「缺什么一眼看见」。
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

        addCheck(arr, "cjh", "AI 引擎 cjh（内置）",
            firstExisting([cjhPath()]),
            "把 cjh.exe 放到应用目录或用 LINGQU_CJH 指向它；缺了 AI 面板不可用（其余功能照常）")

        var res = JsonObject()
        res.put("items", arr)
        res.put("cjh_port", JsonInt(CJH_PORT))
        res.put("platform", JsonString("desktop"))
        return res
    }
}

// ============================================================
// ② cjh 引擎接入（t2h:cjh_*）
// ============================================================

/** 探测 cjh web 是否在跑（前端每次进界面都问一次） */
public class CjhProbeCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, _: JsonObject, _: IpcContext): JsonValue {
        let alive = probePort(CJH_BIND, CJH_PORT)
        var res = JsonObject()
        res.put("alive", JsonBool(alive))
        res.put("endpoint", JsonString("http://${CJH_BIND}:${CJH_PORT}"))
        return res
    }
}

/**
 * 拉起内置 cjh：`cjh web --port 8765 --bind 127.0.0.1`。
 *
 * 用 launchHidden 而不是 std.process.launch：本应用产物是 GUI 子系统，
 * 直接拉一个控制台程序在 Windows 上会蹦出黑窗口（框架已把这条下沉到 C 桥）。
 *
 * 语义对齐 ai-chat：**复用优先**——已在跑就直接复用，不抢用户的实例；
 * 只有本命令拉起的那一份才由本应用收尾。
 */
public class CjhStartCommand <: CommandHandler {
    public init() {}

    public func handle(_: String, args: JsonObject, _: IpcContext): JsonValue {
        var res = JsonObject()

        // ① 复用优先
        if (probePort(CJH_BIND, CJH_PORT)) {
            res.put("ok", JsonBool(true))
            res.put("reused", JsonBool(true))
            res.put("pid", JsonInt(-1))
            res.put("endpoint", JsonString("http://${CJH_BIND}:${CJH_PORT}"))
            res.put("detail", JsonString("8765 上已有 cjh 在跑，直接复用"))
            return res
        }

        // ② 没有就拉起（前端可传 path 覆盖）
        let path = argString(args, "path", cjhPath())
        if (!exists(path)) {
            res.put("ok", JsonBool(false))
            res.put("reused", JsonBool(false))
            res.put("pid", JsonInt(-1))
            res.put("detail", JsonString("找不到 cjh 可执行文件：${path}"))
            return res
        }

        match (launchHidden(path, ["web", "--port", "${CJH_PORT}", "--bind", CJH_BIND])) {
            case Some(p) =>
                res.put("ok", JsonBool(true))
                res.put("reused", JsonBool(false))
                res.put("pid", JsonInt(p.processId()))
                res.put("endpoint", JsonString("http://${CJH_BIND}:${CJH_PORT}"))
                res.put("detail", JsonString("已拉起 cjh（pid ${p.processId()}），等待健康检查"))
            case None =>
                res.put("ok", JsonBool(false))
                res.put("reused", JsonBool(false))
                res.put("pid", JsonInt(-1))
                res.put("detail", JsonString("cjh 启动失败：${path}（看 stderr / 杀软拦截）"))
        }
        return res
    }
}

// ============================================================
// 业务装配点
// ============================================================

/**
 * 骨架阶段只装三条命令（环境体检 + cjh 探测/拉起）。
 * 下一步按迁移引擎的规划挂载：t2h:scan / t2h:deps / t2h:port / t2h:build / t2h:deploy / t2h:verify。
 * 新命令记得同步 assets/capabilities/default.json，否则前端拿到 command not allowed。
 */
public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("lingqu", 1280, 840))
        .wire({ app =>
            app.register("t2h:env", EnvCommand())
            app.register("t2h:cjh_probe", CjhProbeCommand())
            app.register("t2h:cjh_start", CjhStartCommand())
        })
}
