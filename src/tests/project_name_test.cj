package lingqu.tests

import lingqu.scanner.*

/*
 * `--path .` 的落档名（0.39.2 的 bug）。
 *
 * 现场：agent 按我们的任务书在工程根用 `--path .` 跑 `lingqu-cli build`，
 * 落档写成了 `..json / ..jsonl / ..log` —— 因为 projectNameOf(".") 把 `"."` 当名字，
 * sanitizeFileName 再把它清成空串。而「在工程根用 `--path .`」正是我们自己教的写法。
 *
 * 这里钉住解析规则（cwd 注入进来，纯函数可测）。
 */

@Test
public func testProjectNameFromDotUsesCwd(): Unit {
    // 最常见：agent 在工程根用 `--path .`
    @Assert(projectNameOfPath(".", "E:/test/rust/m3u8dl-tauri"), "m3u8dl-tauri")
    @Assert(projectNameOfPath("./", "E:/test/rust/m3u8dl-tauri"), "m3u8dl-tauri")
    @Assert(projectNameOfPath("", "E:/test/rust/m3u8dl-tauri"), "m3u8dl-tauri")
    // cwd 带反斜杠也一样
    @Assert(projectNameOfPath(".", "E:\\test\\rust\\m3u8dl-tauri"), "m3u8dl-tauri")
    // `..` → 上一级末段
    @Assert(projectNameOfPath("..", "E:/test/rust/m3u8dl-tauri"), "rust")
}

@Test
public func testProjectNameFromRelativeAndAbsolute(): Unit {
    // 相对子路径
    @Assert(projectNameOfPath("./src-tauri", "E:/a/proj"), "src-tauri")
    @Assert(projectNameOfPath("src-tauri", "E:/a/proj"), "src-tauri")
    // 绝对路径照旧取末段（这是 0.6.0 起就对的路径，别改坏）
    @Assert(projectNameOfPath("E:/test/rust/habit-tree", "C:/anywhere"), "habit-tree")
    @Assert(projectNameOfPath("E:\\test\\rust\\habit-tree\\", "C:/anywhere"), "habit-tree")
}

@Test
public func testProjectNameDoesNotReturnDotOrEmpty(): Unit {
    // 这几种退化输入都**不许**返回 "." 或空串（否则落档又变成 `..json`）
    for (p in [".", "./", "", "   ", "..", "./."]) {
        let n = projectNameOfPath(p, "E:/w/proj")
        @Assert(n == "." || n.trimAscii().size == 0, false)
    }
}
