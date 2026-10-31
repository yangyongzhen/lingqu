package lingqu.tests

import lingqu.*

/* ---------- 内嵌资源（单文件打包） ---------- */

@Test
public func testDecodeBase64RoundTrip(): Unit {
    // "lingqu" 的 base64 是 bGluZ3F1；带换行/填充也要能解
    @Assert(decodeBase64("bGluZ3F1"), "lingqu")
    @Assert(decodeBase64("bGlu\r\nZ3F1"), "lingqu")
    @Assert(decodeBase64(""), "")
    // 中文（UTF-8 多字节）不丢字节；字面量是 UTF-8 编码后 base64，别手写猜
    @Assert(decodeBase64("54G15rig6L+B56e75Y+w"), "灵渠迁移台")
    // 非法字符按"跳过"处理，不抛
    @Assert(decodeBase64("bGlu!Z3F1"), "lingqu")
}

@Test
public func testSplitBytesBy(): Unit {
    let parts = splitBytesBy("aaa,bbb,ccc", 44)
    @Assert(parts.size, 3)
    @Assert(parts[0], "aaa")
    @Assert(parts[2], "ccc")
    // 空串也切出一段（调用方按 size > 0 兜住）
    @Assert(splitBytesBy("", 44).size, 1)
    // 末尾分隔符会多出一段空串——这与 ai-chat 的取用约定一致
    @Assert(splitBytesBy("aaa,", 44).size, 2)
}

@Test
public func testEmbeddedCapabilitiesEmptyByDefault(): Unit {
    // 仓库内是空存根：正常构建走读盘，不该凭空冒出能力清单
    @Assert(embeddedCapabilityJsons().size, 0)
}

@Test
public func testAssetResolverFallsBackToDisk(): Unit {
    // 内嵌为空时按磁盘读：仓库根下 assets/ui/index.html 一定存在（这也顺带验证了读盘分支）
    let r = LingquAssetResolver("assets")
    match (r.readText("ui/index.html")) {
        case Some(html) => @Assert(html.contains("<html"), true)
        case None => @Assert(true, false)
    }
    @Assert(r.exists("ui/index.html"), true)
    // 不存在的资产回 None（不抛），交给 resolvePage 翻成"资产未找到"
    @Assert(r.exists("ui/nope.html"), false)
}