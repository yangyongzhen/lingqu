package lingqu.tests

import std.collection.*
import std.fs.*
import lingqu.port.*

/*
 * P4 第三刀单测：setup 接线（R2-PORT-010）、对话框资源生成（R2-PORT-014）。
 * 只测纯函数（D-009）；写盘行为由命令层负责。
 */

/** 迁移后 lib.rs 的精简复刻（有 .setup 块、有 009 注入的函数、尚未接线） */
func libRsAfterInjectionFixture(): String {
    return """
    use tauri::Manager;

    fn resolve_app_data_dir(app: &tauri::App) -> Result<PathBuf, tauri::Error> {
        #[cfg(target_env = "ohos")]
        {
            Ok(PathBuf::from("/data/storage/el2/base/files"))
        }
        #[cfg(not(target_env = "ohos"))]
        {
            app.path().app_data_dir()
        }
    }

    fn install_panic_hook(app: &tauri::App) {
        let _ = app;
    }

    #[cfg_attr(mobile, tauri::mobile_entry_point)]
    pub fn run() {
        tauri::Builder::default()
            .setup(|app| {
                let store = 1;
                let _ = store;
                Ok(())
            })
            .run(tauri::generate_context!())
    }
    """
}

@Test
public func testSetupWiringOutcomeDetectsMissingWiring(): Unit {
    // 边界 1：文件读不到 → 跳过（不猜、不 guide）
    let o = setupWiringOutcome("/tmp/lingqu-nonexistent-port-probe/lib.rs")
    @Assert(o.id, "R2-PORT-010")
    @Assert(o.applied, false)
    @Assert(o.note.contains("读不到"), true)
    // 边界 2：文件存在但没有 .setup 块 → guide 档留人工（模板在 after）
    let dir = "/tmp/lingqu-wiring-probe"
    try {
        if (!exists(Path(dir))) {
            Directory.create(Path(dir))
        }
        File.writeTo("${dir}/lib.rs", "fn main() { println!(\"hi\"); }\n".toArray())
    } catch (e: Exception) {
        return // /tmp 不可写则跳过，不造假
    }
    let o2 = setupWiringOutcome("${dir}/lib.rs")
    @Assert(o2.tier, T_GUIDE)
    @Assert(o2.applied, false)
    @Assert(o2.after.contains("install_panic_hook(app)"), true)
}

@Test
public func testApplySetupWiringInsertsAfterSetup(): Unit {
    // 主路径：setup 块后插入 4 行接线（含标记），且幂等
    let before = libRsAfterInjectionFixture()
    let after = applySetupWiring(before)
    @Assert(after.contains("lingqu: R2-PORT-010"), true)
    @Assert(after.contains("install_panic_hook(app);"), true)
    @Assert(after.contains("let dir = resolve_app_data_dir(app)?;"), true)
    // 插入点在 .setup(|app| { 之后、Ok(()) 之前
    let setupIdx = indexOfOr(after, ".setup(|app| {")
    let hookIdx = indexOfOr(after, "install_panic_hook(app);")
    let okIdx = indexOfOr(after, "Ok(())")
    @Assert(hookIdx > setupIdx, true)
    @Assert(hookIdx < okIdx, true)
    // 幂等：再跑一遍文本不变
    let twice = applySetupWiring(after)
    @Assert(twice == after, true)
}

@Test
public func testApplySetupWiringNoSetupBlock(): Unit {
    // 错误路径：没有 .setup 块 → 文本原样返回
    let text = "fn main() { println!(\"hi\"); }\n"
    @Assert(applySetupWiring(text), text)
}

@Test
public func testDialogAssetsContentShape(): Unit {
    let js = dialogJsContent()
    @Assert(js.contains("confirmDialog"), true)
    @Assert(js.contains("promptDialog"), true)
    @Assert(js.contains("lingqu-dialog"), true)
    @Assert(js.contains("lingqu: R2-PORT-014"), true)
    let css = dialogCssContent()
    @Assert(css.contains(".lq-dialog"), true)
    @Assert(css.contains("z-index: 80"), true) // habit-tree 同款层级
}

@Test
public func testFrontendDirOfLayouts(): Unit {
    // 经典布局（Cargo.toml 在 <工程>/src-tauri）：前端目录是工程根，行为不变
    @Assert(frontendDirOf("E:/p/demo", "E:/p/demo/src-tauri", "../dist"), "E:/p/demo/src-tauri/..")
    // 扁平布局（0.39.79 rust-music-2 实测）：srcTauriDir == 工程根，
    // 绝不能退成 "<工程>/.."——那会读到**别的工程**的 lingqu-dialog.js，
    // 表现为 014 假"已存在"+ 012 证据里出现 juCang 路径。
    @Assert(frontendDirOf("C:/w/demo2", "C:/w/demo2", "ui"), "C:/w/demo2/ui")
    @Assert(frontendDirOf("C:/w/demo2", "C:/w/demo2", "./ui"), "C:/w/demo2/ui")
    // 没有 frontendDist / 是绝对或越界路径 → 留在工程根，不拼到外面
    @Assert(frontendDirOf("C:/w/demo2", "C:/w/demo2", ""), "C:/w/demo2")
    @Assert(frontendDirOf("C:/w/demo2", "C:/w/demo2", "../dist"), "C:/w/demo2")
}

@Test
public func testDialogAssetsOutcomeOnNonexistentDir(): Unit {
    // 目录不存在（文件必然不存在）→ applied=true 待生成
    let outs = dialogAssetsOutcome("/tmp/lingqu-nonexistent-port-probe")
    @Assert(outs.size, 1)
    @Assert(outs[0].id, "R2-PORT-014")
    @Assert(outs[0].applied, true)
    @Assert(outs[0].tier, T_AUTO)
}
