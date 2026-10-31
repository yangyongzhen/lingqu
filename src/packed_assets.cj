package lingqu

/**
 * 单文件打包用的内嵌资源（**存根**）。
 *
 * 仓库里这两个量都是空串：正常构建仍按相对路径从 `assets/` 读盘，
 * `packaging/pack-win-single.sh` 会在**临时构建副本**里把本文件覆盖成真实 base64，
 * 于是单个 exe 不再需要随行的 `assets/` 目录（页面与能力清单都在二进制里）。
 *
 * 机制与 `cj-tauri/examples/ai-chat`、`examples/music`、`cjnote` 同款：
 * 判据固定是「非空即内嵌」，取用逻辑在 `src/packed_resources.cj`。
 * 本文件只有数据，**不要往里加代码**——打包脚本是整体覆盖它的。
 */

/** `assets/ui/index.html` 的 base64（空 = 从磁盘读） */
public let PACKED_UI_B64: String = ""

/** `assets/capabilities/` 下各 json 的 base64，多份用英文逗号拼接（空 = 从磁盘读目录） */
public let PACKED_CAPS_B64: String = ""

/**
 * `skills/t2h-ohos-port/SKILL.md` 的 base64（空 = 从磁盘读仓库里那份）。
 *
 * 单文件产物里没有 `skills/` 目录，靠这一份内嵌正文让「安装迁移技能」仍然可用
 * （内嵌副本只含正文、不含 `references` 下的 md 文件；要带参考文档就置 LINGQU_SKILL_SRC 指向仓库重装）。
 */
public let PACKED_SKILL_B64: String = ""
