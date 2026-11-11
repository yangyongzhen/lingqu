package lingqu.tests

import std.collection.*
import std.fs.*

/*
 * 0.39.114 单测：`--login` 只能长在 SignCommand 这一个命令上（读真实源码的判据）。
 *
 * 起因（本轮实测）：`scan/decisions/ai_brief/port/revert/deps/build/hap/migrate/
 * autoport_start` 十个 handler 的 `handle()` 开头，逐字粘了同一段 AGC 登录分支。
 * 后果不是"多写了几行"——只要机器上导出了 `LINGQU_SIGN_LOGIN=1`，这些命令就**全部**
 * 变成"去登录并返回登录结果"，扫描不扫、构建不建，而且一句错都不报（静默劫持）。
 * 224fa58 已经修过轨迹命令那一处，同族的另外十处一直留着。
 *
 * 为什么用"读源码"这种方式断言：这是**结构约束**（哪段代码允许出现在哪个命令里），
 * 纯函数测不到，行为测试要真起登录流程（起回调服务 + 等人点浏览器，分钟级）。
 * 与 `directive_spec_test.cj` 读真实文档同款：读不到文件直接红，不许静默通过。
 */

func mainSrcLinesOf(): Array<String> {
    return String.fromUtf8(File.readFrom("src/main.cj")).split("\n")
}

/** 某行是否含该子串（用 indexOf 判存在，避开手算索引） */
func lineHas(s: String, sub: String): Bool {
    return match (s.indexOf(sub)) {
        case Some(_) => true
        case None => false
    }
}

/** 该子串在源码里出现的行号（1 基，便于失败时直接定位） */
func linesWithOf(src: Array<String>, sub: String): ArrayList<Int64> {
    let hit = ArrayList<Int64>()
    for (i in 0..src.size) {
        if (lineHas(src[i], sub)) {
            hit.add(i + 1)
        }
    }
    return hit
}

/** 行号落在哪个 `public class *Command` 段里（找不到归属返回空串） */
func ownerCommandOf(src: Array<String>, lineNo: Int64): String {
    var owner = ""
    var i = 0
    while (i < src.size && i + 1 <= lineNo) {
        let t = src[i].trimAscii()
        if (t.startsWith("public class ") && lineHas(t, "Command") && lineHas(t, "<:")) {
            owner = t
        }
        i += 1
    }
    return owner
}

@Test
public func testLoginEntryExistsExactlyOnce(): Unit {
    let src = mainSrcLinesOf()
    // guard 表达式（不是注释里的字样）：全仓只许一处
    let hits = linesWithOf(src, "argBool(args, \"login\", false) || envOr(\"LINGQU_SIGN_LOGIN\"")
    @Assert(hits.size, 1)
    if (hits.size == 1) {
        let owner = ownerCommandOf(src, hits[0])
        // 且必须落在 SignCommand 里——粘到别的命令上就是"命令被静默劫持"
        @Assert(owner.startsWith("public class SignCommand"), true)
    }
}

@Test
public func testNoOtherHandlerCarriesAgcLogin(): Unit {
    let src = mainSrcLinesOf()
    // agcLogin( 是真正干活的调用：只允许出现在 SignCommand（登录）与 sign_apply 那条自动链上，
    // 后者不在本文件。本文件里多于 1 处就说明又有人把这段粘出去了。
    let calls = linesWithOf(src, "let outc = agcLogin(")
    @Assert(calls.size, 1)
    if (calls.size == 1) {
        @Assert(ownerCommandOf(src, calls[0]).startsWith("public class SignCommand"), true)
    }
}

@Test
public func testLoginGuardSitsBeforeAnyWork(): Unit {
    let src = mainSrcLinesOf()
    let hits = linesWithOf(src, "argBool(args, \"login\", false) || envOr(\"LINGQU_SIGN_LOGIN\"")
    if (hits.size != 1) {
        return
    }
    // 登录分支必须在 `handle` 的最前面：它一旦排到读 path / 校验之后，
    // "只登录"就没法在缺工程路径时工作（登录与工程无关）
    var handleLine: Int64 = 0
    var i = 0
    while (i < src.size && i + 1 < hits[0]) {
        if (lineHas(src[i], "public func handle(") && ownerCommandOf(src, i + 1).startsWith("public class SignCommand")) {
            handleLine = i + 1
        }
        i += 1
    }
    @Assert(handleLine > 0, true)
    // handle 开头到登录入口之间只允许空行与注释：出现 `var path =` 之类的取值就说明排错了
    if (handleLine > 0) {
        var j = handleLine
        var bad = 0
        while (j < hits[0] - 1) {
            let t = src[j].trimAscii()
            if (t.size > 0 && !t.startsWith("//")) {
                bad += 1
            }
            j += 1
        }
        @Assert(bad, 0)
    }
}
