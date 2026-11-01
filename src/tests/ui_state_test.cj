package lingqu.tests

import lingqu.*

/*
 * 启动带回上次工程：**落档即真值**（0.39.44）。
 *
 * 起因（用户要求「启动时自动带回上次工程」）：先在界面上用 `localStorage` 记工程，
 * 结果两次冷启动都还是「未选工程」。查下去才发现本应用页面跑在 WebView2 里，
 * `localStorage.setItem` 直接抛 `SecurityError`（`LINGQU_UI_PROBE=store` 自检证据：
 * `storeProbe = before||SecurityError|tauri://localhost`）。
 *
 * 所以真值只能来自落档：上一次 `t2h:ui_report` 写的 `.lingqu/ui-report.json` 里就有
 * `currentProject`。这里把"从这份 JSON 文本里取上次工程"钉成纯函数单测——
 * 取不到/坏档都不能抛异常（否则启动即崩，比带不回工程严重得多）。
 */

@Test
public func testLastProjectOfNormal(): Unit {
    let text = "{\"currentProject\":\"C:/Users/yang/Desktop/test/m3u8dl-tauri\",\"width\":1264}"
    @Expect(lastProjectOf(text), "C:/Users/yang/Desktop/test/m3u8dl-tauri")
}

@Test
public func testLastProjectOfBackslashPath(): Unit {
    let text = "{\"currentProject\":\"E:\\\\test\\\\rust\\\\m3u8dl-tauri\"}"
    @Expect(lastProjectOf(text), "E:\\test\\rust\\m3u8dl-tauri")
}

@Test
public func testLastProjectOfMissingKey(): Unit {
    // 没有这个键 → 空串（不能返回别的字段充数）
    @Expect(lastProjectOf("{\"width\":1264}"), "")
    // 类型不对也是空串
    @Expect(lastProjectOf("{\"currentProject\":123}"), "")
}

@Test
public func testLastProjectOfBrokenInput(): Unit {
    // 空文本 / 坏 JSON / 只有空白：一律空串，绝不抛异常
    @Expect(lastProjectOf(""), "")
    @Expect(lastProjectOf("   "), "")
    @Expect(lastProjectOf("{\"currentProject\":"), "")
    @Expect(lastProjectOf("null"), "")
}

@Test
public func testLastProjectOfEmptyValue(): Unit {
    // 上次报告时其实也没选工程（currentProject 是空串）→ 仍然空串，别把它当路径
    @Expect(lastProjectOf("{\"currentProject\":\"\"}"), "")
}

@Test
public func testShouldRestoreLastProjectChecksExistence(): Unit {
    // 0.39.48：带回之前必须判"它还在不在"——
    // 用户实测场景就是"上次的工程目录已被删"，带回来等于把「路径不存在」甩给用户
    @Expect(shouldRestoreLastProject("C:/work/demo", true), true)
    @Expect(shouldRestoreLastProject("C:/work/demo", false), false)
    // 空 / 只有空白：不带回（别把空串当工程）
    @Expect(shouldRestoreLastProject("", true), false)
    @Expect(shouldRestoreLastProject("   ", true), false)
    // 反例：磁盘上没有就一律不带（哪怕路径写得再正确）
    @Expect(shouldRestoreLastProject("E:\\deleted\\proj", false), false)
}
