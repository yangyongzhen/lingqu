package lingqu.tests

import lingqu.port.*

/*
 * 0.39.119：`R2-PORT-008` 生成的 `.cargo/config.toml` **默认带国内镜像**。
 *
 * 起因是 EcoPaste 首轮真实迁移：`cargo build` 卡在 `Downloading crates ...` 整整 18 分钟
 * 零字节（crates.io 走 Fastly，国内直连慢/抖），界面还已经报「停滞」，极易误诊成工具挂死。
 * 与其让每个工程各踩一次，不如生成配置时就配好 rsproxy 稀疏索引。
 */
@Test
public func testCargoConfigHasCnMirrorByDefault(): Unit {
    let t = cargoConfigToml("D:/oh/native")
    // 默认带镜像：源替换 + rsproxy 稀疏索引
    @Expect(t.contains("rsproxy"), true)
    @Expect(t.contains("replace-with"), true)
    // 但**不能顶掉**工具链配置：OHOS target 段与 [env] 段都还在
    @Expect(t.contains("aarch64-unknown-linux-ohos"), true)
    @Expect(t.contains("OHOS_NDK_HOME"), true)
    // 纯 env 片段（追加给"已有 .cargo/config.toml"的工程）**刻意不带**源替换：
    // 别人的源替换不该被我们悄悄改掉
    @Expect(cargoEnvOnlyToml("D:/oh/native").contains("rsproxy"), false)
}
