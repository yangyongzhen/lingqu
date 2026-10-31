package lingqu

/*
 * 「当前工程」的取值规则（0.39.8）
 *
 * 缺陷背景：界面原本每屏一个路径框（一键迁移 / 项目与环境 / 迁移画像 / 依赖树 / 改造执行 /
 * 构建打包 / 真机验证 / 报告，共 8 个），彼此不同步——填错一个就会对着**另一个工程**干活
 * （例如 build 用 A、deploy 用 B），而且顶部还显示着上一次的工程名。
 *
 * 修法：顶部「当前工程」是唯一权威，其余 8 处只做回显；某一步要单独指定，必须显式覆盖。
 * 这里放**纯函数**，前端 `effectivePathFor()` 与它同一口径，便于单测与回归。
 */

/**
 * 生效路径：本步骤覆盖优先，否则用当前工程。
 *
 * @param currentProject 顶部「当前工程」（空 = 还没选）
 * @param stepOverride   本步骤的显式覆盖（空 = 跟随当前工程）
 * @return 实际传给 `t2h:*` 的路径；两者都空 → 空串（调用方必须拦住并提示"先选工程"）
 */
public func effectivePath(currentProject: String, stepOverride: String): String {
    let ov = stepOverride.trimAscii()
    if (ov.size > 0) {
        return ov
    }
    return currentProject.trimAscii()
}

/** 界面里有多少处"要用户填工程路径"——修好后应为 1（只有顶部那个权威输入） */
public let PROJECT_PROMPT_COUNT: Int64 = 1

/** 只做回显、不该让用户重复填的路径框数量 */
public let PROJECT_ECHO_FIELDS: Int64 = 8