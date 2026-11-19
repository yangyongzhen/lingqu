package lingqu.tests

import lingqu.compiler.*

/*
 * 0.39.126（R-2 环境关）单测：修 `.cargo/config.toml` 的两类必然挡路项。
 *
 * 起因：三个未归纳样本的交叉编译首个失败点**全是环境**（不是 crate）——
 * cc-switch 的 `.cargo/config.toml` 写死过期 SDK `HarmonyOS-NEXT-DB6`（目录不存在），
 * tauri-mqtt 的 `ring` 因缺 target CC 拿宿主 cc。这两条不修，R-2 的 crate 级分母永远是 1。
 */

@Test
public func testQuotedValueAndTail(): Unit {
    // 只认引号内的值；单引号/无引号一律不认（避免把注释里的路径当配置）
    @Expect(quotedValueOf("linker = \"D:/oh/x/llvm/bin/clang\""), "D:/oh/x/llvm/bin/clang")
    @Expect(quotedValueOf("linker = D:/oh/x"), "")
    // 尾巴只认 SDK 里那几个固定位置
    @Expect(sdkTailOf("C:/a/sdk/HarmonyOS-NEXT-DB6/openharmony/native/llvm/bin/clang"), "llvm/bin/clang")
    @Expect(sdkTailOf("C:/a/sdk/x/sysroot"), "sysroot")
    @Expect(sdkTailOf("C:/a/sdk/x/native/llvm/bin/llvm-ar"), "llvm/bin/llvm-ar")
    // 认不出就不动（别把普通路径误当 SDK 路径改坏）
    @Expect(sdkTailOf("C:/users/me/project"), "")
}

@Test
public func testRewriteStaleSdkLine(): Unit {
    let ndk = "D:/oh/DevEcoStudio/sdk/default/openharmony/native"
    // 过期 SDK → 按 NDK 重写同一尾巴，行内其它内容保持不变
    @Expect(rewriteStaleSdkLineOf("linker = \"C:/old/HarmonyOS-NEXT-DB6/openharmony/native/llvm/bin/clang\"", ndk),
        "linker = \"D:/oh/DevEcoStudio/sdk/default/openharmony/native/llvm/bin/clang\"")
    // 已经在 ndk 下 → 原样
    let same = "ar = \"D:/oh/DevEcoStudio/sdk/default/openharmony/native/llvm/bin/llvm-ar\""
    @Expect(rewriteStaleSdkLineOf(same, ndk), same)
    // 认不出尾巴 / 空 NDK → 原样（宁可不改，也不猜）
    @Expect(rewriteStaleSdkLineOf("x = \"C:/foo/bar\"", ndk), "x = \"C:/foo/bar\"")
    @Expect(rewriteStaleSdkLineOf("linker = \"C:/old/native/llvm/bin/clang\"", ""), "linker = \"C:/old/native/llvm/bin/clang\"")
}

@Test
public func testHasCDep(): Unit {
    @Expect(hasCDepOf("[[package]]\nname = \"ring\"\nversion = \"0.17.14\""), true)
    @Expect(hasCDepOf("[[package]]\nname = \"libdbus-sys\""), true)
    @Expect(hasCDepOf("[[package]]\nname = \"glib-sys\""), true)
    // 纯 Rust 依赖树不该被判成"要 CC"（否则会白改工程配置）
    @Expect(hasCDepOf("[[package]]\nname = \"serde\"\nname = \"tokio\""), false)
}
