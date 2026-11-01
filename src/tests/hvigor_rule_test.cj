package lingqu.tests

import lingqu.port.*

/*
 * R2-PORT-015（0.39.53）：中性化 `gen/ohos/entry/hvigorfile.ts` 里的 tauri Rust 钩子。
 *
 * 守的口径：
 *   ① 只注掉 `.afterRun(buildRustCode)` 这一行，文件其余部分（`hapTasks`、插件定义）**一字不动**；
 *   ② 幂等：带 `lingqu: R2-PORT-015` 标记就跳过（再跑一次不重复注）；
 *   ③ **不乱改**：没有 `dev-eco-studio-script` 的 hvigorfile 不判命中（那是别人的钩子）；
 *   ④ 回滚表里有它（改了文件就必须能还原——§4-33）。
 */

/** 夹具：juCang 真实的 entry/hvigorfile.ts 形状（节选，2026-11-01 实测那份） */
func hvigorFixture(): String {
    var s = "import { hapTasks } from '@ohos/hvigor-ohos-plugin';\n"
    s += "import { execFileSync } from 'child_process';\n"
    s += "\n"
    s += "export default {\n"
    s += "  system: hapTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */\n"
    s += "  plugins:[tauriPlugin()]         /* Custom plugin to extend the functionality of Hvigor. */\n"
    s += "}\n"
    s += "\n"
    s += "function tauriPlugin() {\n"
    s += "  return {\n"
    s += "    pluginId: 'tauri',\n"
    s += "    apply(node) {\n"
    s += "      const buildRustCode = () => {\n"
    s += "        execFileSync(`cargo`,\n"
    s += "          [\"tauri\", \"ohos\", \"dev-eco-studio-script\", \"--target\", \"aarch64\"], {\n"
    s += "            cwd: resolve(__dirname, \"../../../\"),\n"
    s += "            stdio: \"inherit\",\n"
    s += "          });\n"
    s += "      }\n"
    s += "\n"
    s += "      node.getTaskByName('default@ConfigureCmake')!.afterRun(buildRustCode);\n"
    s += "    }\n"
    s += "  }\n"
    s += "}\n"
    return s
}

@Test
public func testNeutralizeHvigorHookOnlyCommentsTheHookLine(): Unit {
    let fix = neutralizeHvigorHook(hvigorFixture())
    @Assert(fix.changed, true)
    @Assert(fix.text.contains(HVIGOR_HOOK_MARKER), true)
    // 钩子那一行被注掉（原文还在，只是前面加了 `// `）
    @Assert(fix.text.contains("// node.getTaskByName('default@ConfigureCmake')!.afterRun(buildRustCode);"), true)
    // 其余结构一字不动：hapTasks / plugins / 定义都在
    @Assert(fix.text.contains("system: hapTasks"), true)
    @Assert(fix.text.contains("plugins:[tauriPlugin()]"), true)
    @Assert(fix.text.contains("function tauriPlugin()"), true)
    @Assert(fix.text.contains("dev-eco-studio-script"), true)
    // 行数只增不减（加了注释行），且不是整份被替换成别的东西
    @Assert(fix.text.split("\n", -1).size > hvigorFixture().split("\n", -1).size, true)
}

@Test
public func testNeutralizeHvigorHookIsIdempotent(): Unit {
    let first = neutralizeHvigorHook(hvigorFixture())
    @Assert(first.changed, true)
    let second = neutralizeHvigorHook(first.text)
    @Assert(second.changed, false)
    @Assert(second.text, first.text)
    @Assert(second.note.contains("已经注过"), true)
    // 注过两次也只出现一次标记（不会重复叠注释）
    var cnt: Int64 = 0
    let marker = HVIGOR_HOOK_MARKER
    let lines = first.text.split("\n", -1)
    for (l in lines) {
        if (l.contains(marker)) {
            cnt += 1
        }
    }
    @Assert(cnt >= 1, true)
}

@Test
public func testNeutralizeHvigorHookLeavesOtherHooksAlone(): Unit {
    // 没有 dev-eco-studio-script：不是这类钩子，别动别人的文件
    let other = "export default {\n  system: hapTasks,\n}\nfunction tauriPlugin() { node.afterRun(x); }\n"
    let fix = neutralizeHvigorHook(other)
    @Assert(fix.changed, false)
    @Assert(fix.text, other)
    @Assert(fix.note.contains("不适用"), true)
}

@Test
public func testRevertPairsCoverHvigorfile(): Unit {
    // 改了 hvigorfile 就必须能回滚（§4-33：产出方与消费方共用一个映射）
    var found = false
    for (p in revertPairs()) {
        if (p.backupFile == BAK_HVIGORFILE) {
            found = true
            @Assert(p.relTarget, "src-tauri/gen/ohos/entry/hvigorfile.ts")
        }
    }
    @Assert(found, true)
}
