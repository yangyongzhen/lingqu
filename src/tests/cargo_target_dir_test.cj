package lingqu.tests

import lingqu.*

/*
 * 0.39.135：`.so` 定位要尊重工程自己的 `build.target-dir`。
 *
 * 现场（2026-11-21 dbx）：dbx 因 C 盘只剩 ~2G，把 `target-dir` 配到 `E:/tmp/dbx-target`，
 * 而 `t2h:build` 一直按 `<srcDir>/target/<triple>/release` 找 `.so` ⇒
 * `exitCode=0` 却报「编译成功但没产出 libdbx_lib.so」（假红；§4-151 同族：找错位置 ≠ 没产出）。
 */
@Test
public func testTargetDirInCargoConfig(): Unit {
    // 正常：`[build]` 段里带引号
    let normal = "[env]\nFOO = \"1\"\n\n[build]\ntarget-dir = \"E:/tmp/dbx-target\"\n"
    @Expect(targetDirInCargoConfigOf(normal), "E:/tmp/dbx-target")
    // 只认 `[build]` 段的键：`[env]` 段里的同名前缀不算
    let envOnly = "[env]\ntarget-dir-shadow = \"x\"\n"
    @Expect(targetDirInCargoConfigOf(envOnly), "")
    // 没有 `[build]` 段
    @Expect(targetDirInCargoConfigOf("[env]\nA = \"b\"\n"), "")
}

@Test
public func testParentDirOfBothSeparators(): Unit {
    @Expect(parentDirOf("E:/a/b"), "E:/a")
    @Expect(parentDirOf("E:\\a\\b"), "E:\\a")
    // 没有分隔符 ⇒ 空（调用方据此停止上溯）
    @Expect(parentDirOf("nope"), "")
}
