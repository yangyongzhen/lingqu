package lingqu

import std.collection.*
import std.fs.*
import cjTauri.platform.*

/*
 * 内嵌资源的取用层（单文件打包用）。
 *
 * 分工：
 *   · `PACKED_UI_B64` / `PACKED_CAPS_B64`（`src/packed_assets.cj`）由打包脚本写入，仓库里是空串；
 *   · 本文件负责「解码」与「**内嵌优先、否则读盘**」两件事，正常构建走读盘那条，行为与以前一致。
 *
 * 为什么 base64 而不是生成字符串字面量：页面正文有成片的引号与反斜杠，
 * 手工转义错一个字符就是整段脚本静默不执行（AGENTS §4-28 的多行字符串坑）。
 * base64 字符表只有 `A-Za-z0-9+/=`，生成与解码都不涉及转义，坏不了。
 */

/** 取 base64 字符的值；`=` 与空白一并返回 -1（由调用方跳过） */
func b64Value(b: UInt8): Int64 {
    if (b >= 65 && b <= 90) {          // A-Z
        return Int64(b - 65)
    }
    if (b >= 97 && b <= 122) {         // a-z
        return Int64(b - 97) + 26
    }
    if (b >= 48 && b <= 57) {          // 0-9
        return Int64(b - 48) + 52
    }
    if (b == 43) {                     // +
        return 62
    }
    if (b == 47) {                     // /
        return 63
    }
    return -1
}

/** 标准 base64 → UTF-8 文本（末尾 `=` 天然被跳过：少几位就少吐几个字节） */
public func decodeBase64(s: String): String {
    let out = ArrayList<Byte>()
    var acc: Int64 = 0
    var bits: Int64 = 0
    for (b in s) {
        let v = b64Value(b)
        if (v < 0) {
            continue
        }
        acc = (acc << 6) | v
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.add(UInt8((acc >> bits) & 0xFF))
        }
    }
    return String.fromUtf8(out.toArray())
}

/** 按单字节分隔符切分（只服务"多段 base64 用逗号拼接"这一种输入，base64 表里没有逗号） */
public func splitBytesBy(s: String, sep: UInt8): ArrayList<String> {
    let out = ArrayList<String>()
    var buf = ArrayList<Byte>()
    for (b in s) {
        if (b == sep) {
            out.add(String.fromUtf8(buf.toArray()))
            buf = ArrayList<Byte>()
            continue
        }
        buf.add(b)
    }
    out.add(String.fromUtf8(buf.toArray()))
    return out
}

/**
 * 资产解析器：**内嵌优先，缺则读盘**。
 *
 * 装配期由 `wire()` 注入（替换骨架默认的 DirectoryAssetResolver）。这样：
 *   · 单文件产物：页面从 `PACKED_UI_B64` 解码，不需要 `assets/` 目录，也就不再依赖工作目录；
 *   · 仓库内构建（`PACKED_UI_B64` 为空）：照旧按 `assets/<name>` 读盘，行为不变。
 *
 * 读不到返回 `None` 而不是抛异常——`resolvePage` 会把它翻成"资产未找到"的可照做报错。
 */
public class LingquAssetResolver <: AssetResolver {
    /** 读盘时用的资产根（相对工作目录），通常就是 `assets` */
    private let root: String

    public init(root: String) {
        this.root = root
    }

    public func readText(name: String): Option<String> {
        if (PACKED_UI_B64.size > 0 && isMainPage(name)) {
            return Some(decodeBase64(PACKED_UI_B64))
        }
        let p = Path(root + "/" + name)
        try {
            if (exists(p)) {
                return Some(String.fromUtf8(File.readFrom(p)))
            }
        } catch (e: Exception) {
            let _ = e
        }
        return None
    }

    /**
     * 按字节取内容：图标 / 音频这类二进制资产（框架 issue #13：`readText` 只能装文本）。
     *
     * 0.39.129 起本地框架（cj-tauri 2.4.0+）的 `AssetResolver` 要求本方法；
     * 旧框架下它是多余方法，无害。内嵌主页只有文本（HTML），从 base64 解出的文本转字节，
     * 与 `readText` 同源；磁盘资产按原始字节读。
     */
    public func readBytes(name: String): Option<Array<Byte>> {
        if (PACKED_UI_B64.size > 0 && isMainPage(name)) {
            return Some(decodeBase64(PACKED_UI_B64).toArray())
        }
        let p = Path(root + "/" + name)
        try {
            if (exists(p)) {
                return Some(File.readFrom(p))
            }
        } catch (e: Exception) {
            let _ = e
        }
        return None
    }

    /** `ui/index.html` 与 `index.html` 都认（清单里写的是前者） */
    func isMainPage(name: String): Bool {
        return name == "ui/index.html" || name == "index.html"
    }

    /** 接口要求：以「能否读到」为准（与 DirectoryAssetResolver 同口径） */
    public func exists(name: String): Bool {
        match (readText(name)) {
            case Some(_) => return true
            case None => return false
        }
    }
}

/**
 * 内嵌的能力清单（`PACKED_CAPS_B64` 里逗号分隔的多份）。
 *
 * 为什么需要它：骨架的 `.capabilities("assets/capabilities")` 是**按目录读盘**的，
 * 单文件产物里没有这个目录 → 清单为 0 → 所有命令都 `command not allowed`。
 * 装配顺序上 `wire()` 在 `loadCapabilities()` 之后，所以在这里补挂即可。
 */
public func embeddedCapabilityJsons(): ArrayList<String> {
    let out = ArrayList<String>()
    if (PACKED_CAPS_B64.size == 0) {
        return out
    }
    for (part in splitBytesBy(PACKED_CAPS_B64, 44)) {
        if (part.size == 0) {
            continue
        }
        out.add(decodeBase64(part))
    }
    return out
}
