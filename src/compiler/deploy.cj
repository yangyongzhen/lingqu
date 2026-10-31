package lingqu.compiler

import std.collection.*
import stdx.encoding.json.*

/*
 * T5-5 真机部署的纯函数半边：解析 `hdc` 的输出。
 *
 * 实测口径（2026-10-30，hdc 3.2.0d，DevEco 6.1.1.300）：
 *   · `hdc list targets`            → 每行一个序列号；没有设备时是 `[Empty]`
 *   · `hdc list targets -v`         → 还会列出 `COM1  UART  Ready  unknown...  hdc` 这类**串口噪声**，
 *                                     那不是设备（本项目踩过：把 COM 口当设备会误报"幽灵设备"）
 *   · `hdc install -r <hap>`        → 成功含 `install bundle successfully`
 *   · `hdc shell aa start -a <ability> -b <bundle>` → 启动
 *   · `hdc shell hilog` / `hdc hilog`→ 日志
 * 失败码里与本项目指纹库同源的有：9568322（签名/无 device-ids）、9568269（安装路径）、
 * 10106102（锁屏拒绝自动解锁）。
 */

/** 一个在线设备 */
public class HdcDevice {
    public var serial: String
    public var state: String   // 通常为空；`Connected` / `Offline` 之类原样保留

    public init(serial: String, state: String) {
        this.serial = serial
        this.state = state
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("serial", JsonString(this.serial))
        o.put("state", JsonString(this.state))
        return o
    }
}

/** 解析 `hdc list targets`（含 -v 形态）→ 只留真设备 */
public func parseHdcTargets(text: String): ArrayList<HdcDevice> {
    let out = ArrayList<HdcDevice>()
    for (raw in text.split("\n", -1)) {
        let line = raw.trimAscii()
        if (line.size == 0 || line == "[Empty]") {
            continue
        }
        // 串口噪声：COM1  UART  Ready  unknown...  hdc
        if (line.startsWith("COM") || line.contains("UART")) {
            continue
        }
        // 常见形态：`<serial>` 或 `<serial>\t<state>` 或 `127.0.0.1:5555\tTCP\tConnected`
        let parts = line.split("\t", -1)
        let serial = parts[0].trimAscii()
        if (serial.size == 0) {
            continue
        }
        // 纯串口号再挡一次（防止 COM 无 UART 字样）
        if (isComPort(serial)) {
            continue
        }
        var state = ""
        if (parts.size > 1) {
            state = parts[parts.size - 1].trimAscii()
        }
        // `127.0.0.1:5555` 这类 TCP 目标后面常跟 Connected/Offline
        var exists = false
        for (d in out) {
            if (d.serial == serial) {
                exists = true
                break
            }
        }
        if (!exists) {
            out.add(HdcDevice(serial, state))
        }
    }
    return out
}

/** COM1 / COM12 这类串口名 */
func isComPort(s: String): Bool {
    if (!s.startsWith("COM")) {
        return false
    }
    if (s.size <= 3) {
        return false
    }
    let rest = s[3..]
    for (b in rest.toArray()) {
        if (b < 48 || b > 57) {
            return false
        }
    }
    return true
}

/** 部署动作的结果 */
public class DeployStep {
    public var name: String
    public var ok: Bool
    public var detail: String
    /** hdc 输出里的失败码（9568322 等），没有则 0 */
    public var failCode: Int64

    public init(name: String, ok: Bool, detail: String, failCode: Int64) {
        this.name = name
        this.ok = ok
        this.detail = detail
        this.failCode = failCode
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("name", JsonString(this.name))
        o.put("ok", JsonBool(this.ok))
        o.put("detail", JsonString(this.detail))
        o.put("failCode", JsonInt(this.failCode))
        return o
    }
}

/** hdc 输出里的已知失败码（与 diagnose.cj 的指纹库同源；直接比字面量，不依赖字符串→数字解析） */
public func hdcFailCodeOf(text: String): Int64 {
    if (text.contains("9568322")) {
        return 9568322
    }
    if (text.contains("9568269")) {
        return 9568269
    }
    if (text.contains("10106102")) {
        return 10106102
    }
    if (text.contains("9568332")) {
        return 9568332
    }
    if (text.contains("9568289")) {
        return 9568289
    }
    return 0
}

/** 失败码 → 处置建议（与 FP-012/013/014 口径一致） */
public func hdcFailHintOf(code: Int64): String {
    match (code) {
        case 9568322 => return "签名/release 分发问题：装机的 profile 缺 device-ids 或不是调试签名 → 换 debug 签名或把设备 UDID 加进 profile（FP-012）"
        case 9568269 => return "hdc file send 会保留源目录结构 → 先 cd 到 HAP 所在目录再发文件名（FP-013）"
        case 10106102 => return "设备在锁屏，拒绝自动解锁 → 解锁后重试（FP-014）"
        case _ => return ""
    }
}

/**
 * 解析 `hdc install` 的结果。
 * 成功判据：输出含 `install bundle successfully` 且退出码 0（退出码由命令层给，这里只看文本）。
 */
public func parseInstallResult(text: String, exitCode: Int64): DeployStep {
    let code = hdcFailCodeOf(text)
    if (text.contains("install bundle successfully")) {
        return DeployStep("install", true, "install bundle successfully", 0)
    }
    var detail = firstErrorLine(text)
    if (detail == "") {
        detail = firstLines(text, 3)
    }
    let hint = hdcFailHintOf(code)
    if (hint != "") {
        detail = detail + " ｜ 处置：" + hint
    }
    return DeployStep("install", exitCode == 0 && code == 0, detail, code)
}

/** 解析 `aa start` 的结果：成功含 `start ability successfully` 或 `StartAbility success` */
public func parseStartResult(text: String, exitCode: Int64): DeployStep {
    let started = text.contains("start ability successfully") || text.contains("StartAbility success") || text.contains("Operation successful")
    if (started) {
        return DeployStep("start", true, "ability started", 0)
    }
    let code = hdcFailCodeOf(text)
    var detail = firstErrorLine(text)
    if (detail == "") {
        detail = firstLines(text, 3)
    }
    let hint = hdcFailHintOf(code)
    if (hint != "") {
        detail = detail + " ｜ 处置：" + hint
    }
    return DeployStep("start", exitCode == 0 && code == 0, detail, code)
}

/** hilog 尾部：取最后 n 行非空日志（给界面与证据用） */
public func hilogTail(text: String, n: Int64): ArrayList<String> {
    let all = ArrayList<String>()
    for (raw in text.split("\n", -1)) {
        let t = raw.trimAscii()
        if (t != "") {
            all.add(t)
        }
    }
    let out = ArrayList<String>()
    var start: Int64 = 0
    if (all.size > n) {
        start = all.size - n
    }
    var i = start
    while (i < all.size) {
        out.add(all[i])
        i += 1
    }
    return out
}

/** hilog 里是否出现崩溃/panic 痕迹（真机可用性判断的第一道筛子） */
public func hilogLooksHealthy(text: String): Bool {
    for (marker in ["[panic]", "SIGABRT", "SIGSEGV", "FATAL EXCEPTION", "JavaScript error"]) {
        if (text.contains(marker)) {
            return false
        }
    }
    return true
}

/** 部署体检结论（`t2h:deploy` 的判定层，纯函数） */
public class DeployVerdict {
    public var ok: Bool = false
    public var reason: String = ""
    public var nextStep: String = ""

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("reason", JsonString(this.reason))
        o.put("nextStep", JsonString(this.nextStep))
        return o
    }
}

/**
 * 一次部署的四段结论 → 一句话判定 + 可执行下一步。
 *
 * 顺序有意为之：**先设备、再安装、再启动、最后看日志**——每一段都是下一段的前提，
 * 报最靠前的那段失败（后面的"失败"只是前因的后果，报出来反而误导人）。
 * 特别地：`install` 成功但 `aa start` 失败时，多半是 **ability 名/bundle 名不对**，
 * 而**不是**签名或包的问题（这两个我们在 0.17.0 真机上实测过区别）。
 */
public func judgeDeploy(hasDevice: Bool, installOk: Bool, startOk: Bool, hilogHealthy: Bool,
    serial: String, failCode: Int64): DeployVerdict {
    let v = DeployVerdict()
    if (!hasDevice) {
        v.ok = false
        v.reason = "没有在线设备（`hdc list targets` 为空；注意挡掉 `COM1 UART Ready` 这类串口噪声）"
        v.nextStep = "连上鸿蒙设备并开启 USB 调试，或用 `serial` 参数指定目标"
        return v
    }
    if (!installOk) {
        v.ok = false
        v.reason = "安装失败（设备 ${serial}）" + (if (failCode != 0) { "，失败码 ${failCode}" } else { "" })
        v.nextStep = if (failCode != 0) { hdcFailHintOf(failCode) } else { "看 .lingqu/deploy/<工程>.log 里的 hdc 原文" }
        return v
    }
    if (!startOk) {
        v.ok = false
        v.reason = "装上了但启动失败（设备 ${serial}）——多半是 ability/bundle 名不对，不是签名问题"
        v.nextStep = "确认 `aa start -a <ability> -b <bundle>` 的名字：ability 默认 EntryAbility，bundle 在 AppScope/app.json5"
        return v
    }
    if (!hilogHealthy) {
        v.ok = false
        v.reason = "启动成功，但 hilog 里有崩溃/panic 痕迹"
        v.nextStep = "看落档的 hilog 尾部与 /data/log/faultlog/faultlogger/；崩在 ArkTS 侧多半是缺 .so 或资源"
        return v
    }
    v.ok = true
    v.reason = "安装 + 启动成功，hilog 无崩溃痕迹（设备 ${serial}）"
    v.nextStep = "截图确认界面（人眼）；核心功能清单见 ⑥ 屏"
    return v
}

