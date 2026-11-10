package lingqu.compiler

import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/*
 * 自动签名的**编排层**（0.39.18）：把「登录之后」的每一步串起来。
 *
 * 顺序（与 flutter `signing.dart` 的 `_generate` 骨架一致，去掉我们用不上的 ACL 收集）：
 *
 *   ① 读令牌（没有就要求先 `--login`）
 *   ② 团队（登录时already拿到第一个）
 *   ③ 设备：hdc 取 UDID/deviceType → 云端已注册就跳过、否则注册
 *   ④ 材料：按 DevEco 命名规则算出本地四个文件路径（`{product}_{目录}_{hash}=.{p12,csr,cer,p7b}`）
 *         · 本地没有 p12 → `hap-sign-tool generate-keypair`（随机字母数字口令）+ `generate-csr`
 *   ⑤ 证书：按确定性名字 `auto_debug_<teamId>.cer` 精确查找；没有就用 CSR 新建 → 拿到 id 并下载 .cer
 *   ⑥ profile：按新包名申请 debug（带 deviceList）→ 下载 .p7b → 云端 profile 立刻删除
 *   ⑦ 写配置：用本机 `material/` 加密口令 → `applySigningConfig` 写回 build-profile.json5（先 .bak）
 *
 * 每一步都往 `steps` 里记一行"做了什么/为什么跳过"，失败时带**是哪一步**——这类跨 6 个外部系统的
 * 流程，最怕的是"跑完了但不知道哪步没做"（D-013 的老教训）。
 */

/** 编排结果 */
public class AutoSignOutcome {
    public var ok: Bool = false
    /** 逐步日志（一行一步；落档与界面都用它） */
    public var steps: ArrayList<String> = ArrayList<String>()
    public var error: String = ""
    public var teamId: String = ""
    public var certName: String = ""
    public var certId: String = ""
    public var p12Path: String = ""
    public var csrPath: String = ""
    public var cerPath: String = ""
    public var p7bPath: String = ""
    public var buildProfile: String = ""
    public var backup: String = ""
    /** 是否本次新生成了密钥（false = 复用本地已有 p12） */
    public var generatedKeys: Bool = false
    /** 口令长度（只回长度，绝不回明文） */
    public var passwordLen: Int64 = 0

    public func add(s: String): Unit {
        this.steps.add(s)
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("error", JsonString(this.error))
        var arr = JsonArray()
        for (s in this.steps) {
            arr.add(JsonString(s))
        }
        o.put("steps", arr)
        o.put("teamId", JsonString(this.teamId))
        o.put("certName", JsonString(this.certName))
        o.put("certId", JsonString(this.certId))
        o.put("p12", JsonString(this.p12Path))
        o.put("csr", JsonString(this.csrPath))
        o.put("cer", JsonString(this.cerPath))
        o.put("p7b", JsonString(this.p7bPath))
        o.put("buildProfile", JsonString(this.buildProfile))
        o.put("backup", JsonString(this.backup))
        o.put("generatedKeys", JsonBool(this.generatedKeys))
        o.put("passwordLen", JsonInt(this.passwordLen))
        return o
    }
}

/** 一次自动签名的输入 */
public class AutoSignInput {
    /** `~/.ohos/config` */
    public var configDir: String = ""
    /** product 名（通常是 default） */
    public var product: String = "default"
    /** DevEco 眼中的"工程根"：`<工程>/src-tauri/gen/ohos`（**前向斜杠**由内部归一） */
    public var projectRoot: String = ""
    /** 工程的 bundleName（`AppScope/app.json5`） */
    public var bundleName: String = ""
    /** 工程 build-profile.json5 路径 */
    public var buildProfile: String = ""
    /** 本机 UDID（大写） */
    public var udid: String = ""
    /** `hw_sc.build.os.deviceType` 解析出的设备类型码 */
    public var deviceType: String = "4"
    /** 云端 profile 是否保留（默认 false：下载完就删，省配额） */
    public var keepProvision: Bool = false
    /**
     * 丢弃本地旧材料、重新生成密钥对（并把云端那张同名证书换成绑新公钥的）。
     *
     * 为什么需要：材料是从别处拷来的 / `material/` 重建过时，`.p12` 的口令**没人知道**
     * （密文解不开 → 我们没法用本机 workKey 重新加密）→ hvigor 侧必然报
     * `00303242 Signature material verification failed, as: Unsupported state or unable to
     * authenticate data`。这时唯一干净的路是**换一套自己能掌握口令的材料**。
     */
    public var forceNewKeys: Bool = false
}

/**
 * 跑完整条编排（需要已登录的令牌）。
 *
 * `token` 里必须带 `accessToken` / `userId` / `teamId`；缺团队时这里会重新拉一次。
 */
public func autoSign(inp: AutoSignInput, token: AgcLoginOutcome): AutoSignOutcome {
    let out = AutoSignOutcome()
    // ---------------- ① 令牌 ----------------
    if (token.accessToken == "" || token.userId == "") {
        out.error = "没有可用的登录令牌：先跑 `sign --login` 完成一次浏览器授权"
        return out
    }
    var teamId = token.teamId
    if (teamId == "") {
        match (agcTeamList(token.accessToken, token.userId)) {
            case Some(t) =>
                teamId = t.id
                out.add("② 团队：拉到 ${t.name}（${t.id}）")
            case None =>
                out.error = "拉团队列表失败（token 可能已失效，重跑 `sign --login`）"
                return out
        }
    } else {
        out.add("② 团队：用令牌里的 ${token.teamName}（${teamId}）")
    }
    out.teamId = teamId
    // ---------------- ③ 设备 ----------------
    let (devOK, devMsg) = agcEnsureDevice(token.accessToken, token.userId, teamId, inp.udid,
        inp.deviceType)
    out.add("③ 设备：${devMsg}")
    if (!devOK) {
        out.error = devMsg
        return out
    }
    // ---------------- ④ 材料命名与本地密钥 ----------------
    let base = signingFileBaseName(inp.product, inp.projectRoot)
    // 四种材料**同一个前缀**（`<base>=`）：后面凡是拼路径都必须走它，
    // 手抄模板漏掉那个 `=` 就会得到"看着像、其实不存在"的路径（0.39.22 因此让
    // `--newKeys` 静默失效：exists() 全 false，一个文件都没被挪走）。
    let matPrefix = "${inp.configDir}/${base}="
    out.p12Path = "${matPrefix}.p12"
    out.csrPath = "${matPrefix}.csr"
    out.cerPath = "${matPrefix}.cer"
    out.p7bPath = "${matPrefix}.p7b"
    out.add("④ 材料路径（DevEco 同名规则）：${base}=.{p12,csr,cer,p7b}")
    // java / hap-sign-tool 位置（只在需要生成/申请证书时用）
    let javaHome = envOf("JAVA_HOME")
    let devecoHome = firstExistingEnv(["DEVECO_HOME", "DEVECO_SDK_HOME"])
    let sdkHome = firstExistingEnv(["DEVECO_SDK_HOME", "OHOS_HOME"])
    // `DEVECO_SDK_HOME` 没设时按 `DEVECO_HOME/sdk` 推导（DevEco 6.x 的实际布局）：
    // 少了这一步，`--newKeys` 会卡在"找不到 hap-sign-tool.jar"（实测 0.39.22）
    var jarHome = sdkHome
    if (jarHome == "" && devecoHome != "") {
        let guess = hostPathOf("${devecoHome}/sdk")
        if (exists(Path(guess))) {
            jarHome = guess
        }
    }
    let javaPath = javaCandidates(javaHome, devecoHome)
    var javaExe = firstExisting(javaPath)
    if (javaExe == "") {
        javaExe = "java"        // 交给 PATH，失败会在 runSignTool 里带回 exit 码
    }
    let jar = firstExisting(hapSignToolCandidates(jarHome))
    var password = ""
    // 先把旧材料挪开（**改名不删**：私钥不可再生，留一份可回退）
    if (inp.forceNewKeys) {
        for (suffix in [".p12", ".csr", ".cer", ".p7b"]) {
            let p = matPrefix + suffix
            if (!exists(Path(p))) {
                continue
            }
            let dst = "${p}.lingqu-bak-${nowMs()}"
            try {
                File.writeTo(dst, File.readFrom(p))
                remove(Path(p))
                out.add("④ 旧材料已改名留底：${fileNameOf(dst)}")
            } catch (e: Exception) {
                out.error = "④ 挪开旧材料失败（${p}）：${e}"
                return out
            }
        }
    }
    if (!exists(Path(out.p12Path))) {
        if (jar == "") {
            out.error = "本地没有 ${out.p12Path}，且找不到 hap-sign-tool.jar（设 DEVECO_SDK_HOME）"
            return out
        }
        password = randomPasswordAlnum()
        let kp = genKeypair(javaExe, jar, out.p12Path, password, tempDirOf())
        if (!kp.ok) {
            out.error = "④ 生成密钥对失败：${kp.error}"
            return out
        }
        out.generatedKeys = true
        out.passwordLen = Int64(password.size)
        out.add("④ 生成密钥对：${out.p12Path}（口令 ${password.size} 位，未落日志）")
        let csr = genCsr(javaExe, jar, out.p12Path, password, out.csrPath, tempDirOf())
        if (!csr.ok) {
            out.error = "④ 生成 CSR 失败：${csr.error}"
            return out
        }
        out.add("④ 生成 CSR：${out.csrPath}")
    } else {
        out.add("④ 复用本地已有密钥：${out.p12Path}")
    }
    // ---------------- ⑤ 证书 ----------------
    let certName = certNameFor(teamId)
    out.certName = certName
    let (certs, certErr) = agcCertList(token.accessToken, token.userId, teamId)
    if (certErr != "") {
        out.error = "⑤ ${certErr}"
        return out
    }
    out.add("⑤ 云端已有证书 ${certs.size} 张，按名字找 ${certName}")
    var cert = AgcCert()
    // 新建证书时必须**重下**本地 .cer：本地那份对应的是旧证书（多半已过期），
    // 不重下就会拿"新证书 id + 旧证书文件"去签，hvigor 那边报的错会离真正原因很远。
    var freshCert = false
    // 刚生成了新密钥对 → 云端那张同名证书绑的是**旧公钥**，profile 里写的证书会对不上 .p12，
    // 必须换一张；反之（复用旧 p12）云端那张就是这个密钥对的证书，直接复用。
    if (out.generatedKeys) {
        match (findCertByName(certs, certName)) {
            case Some(old) =>
                let oldIds = ArrayList<String>()
                oldIds.add(old.id)
                let (delOK, delNote) = agcCertDelete(token.accessToken, token.userId, teamId, oldIds)
                out.add("⑤ 旧证书绑的是旧密钥，先换掉：${delNote}")
                if (!delOK) {
                    out.error = "⑤ ${delNote}"
                    return out
                }
            case None => ()
        }
    }
    var reusable: Option<AgcCert> = None
    if (!out.generatedKeys) {
        reusable = findUsableCert(certs, certName)
    }
    match (reusable) {
        case Some(c) =>
            cert = c
            out.add("⑤ 复用证书：${certName}（id=${cert.id}）")
        case None =>
            if (!exists(Path(out.csrPath))) {
                out.error = "⑤ 云端没有可用的 ${certName}，本地也没有 CSR 可用来新建（先删掉 p12 让它重生）"
                return out
            }
            var csrText = ""
            try {
                csrText = String.fromUtf8(File.readFrom(out.csrPath))
            } catch (e: Exception) {
                out.error = "⑤ 读 CSR 失败：${e}"
                return out
            }
            // AGC 证书数量有上限（本账号实测 4 张），过期的照样占位 → 先把**自己的**过期自动签名
            // 证书删掉腾位置，否则新建会被回 `205389872 certificate number exceeds limit.`。
            let stale = staleCertsOf(certs)
            if (stale.size > 0) {
                let ids = ArrayList<String>()
                for (s in stale) {
                    ids.add(s.id)
                    out.add("⑤ 过期证书占位：${s.certName}（id=${s.id}，到期 ${s.expireMs}）")
                }
                let (ok, note) = agcCertDelete(token.accessToken, token.userId, teamId, ids)
                out.add("⑤ ${note}")
                if (!ok) {
                    out.error = "⑤ ${note}（可以登录 AGC 控制台手动删除过期证书后重试）"
                    return out
                }
            }
            let (newCert, addErr) = agcCertAdd(token.accessToken, token.userId, teamId, csrText,
                certName, "1")       // 1 = debug 证书
            if (addErr != "") {
                out.error = "⑤ ${addErr}"
                return out
            }
            cert = newCert
            freshCert = true
            out.add("⑤ 新建证书：${certName}（id=${cert.id}）")
    }
    out.certId = cert.id
    out.add("⑤ 证书对象：id=${cert.id} objectId=${cert.certObjectId}")
    if (cert.id == "") {
        out.error = "⑤ 证书没有 id，无法申请 profile"
        return out
    }
    // 本地 .cer：没有（或刚换了新证书）就按 certObjectId 下载
    if (freshCert || !exists(Path(out.cerPath))) {
        let objectRef = if (cert.certObjectId != "") { cert.certObjectId } else { cert.id }
        let (saved, dlErr) = agcDownloadObject(token.accessToken, token.userId, teamId, objectRef,
            out.cerPath)
        if (dlErr != "") {
            out.error = "⑤ 下载证书失败：${dlErr}"
            return out
        }
        out.add("⑤ 下载证书：${saved}")
    } else {
        out.add("⑤ 复用本地证书文件：${out.cerPath}")
    }
    // ---------------- ⑥ profile ----------------
    // `deviceList` 要的是**云端设备 id**（不是 UDID）：AGC 对元素长度有限制（≤32），
    // 而 UDID 是 64 位十六进制 → 直接传 UDID 会被拒：
    //   `signIdeTestProvision.reqParams.deviceList[0].<list element>: size must be between 0 and 32`
    // （实测踩到）。所以先拉 device/list，把 id 收集起来。
    let (cloudDevices, devErr) = agcDeviceList(token.accessToken, token.userId, teamId)
    if (devErr != "") {
        out.error = "⑥ 拉设备列表失败：${devErr}"
        return out
    }
    let deviceIds = ArrayList<String>()
    for (d in cloudDevices) {
        if (d.id != "") {
            deviceIds.add(d.id)
        }
    }
    if (deviceIds.size == 0) {
        out.error = "⑥ 云端没有已注册设备（先跑设备注册，或检查 UDID 是否在团队里）"
        return out
    }
    out.add("⑥ 云端设备 id ${deviceIds.size} 个（用它申请 profile，不是 UDID）")
    let (p7b, provNote) = agcProvisionDebug(token.accessToken, token.userId, teamId, cert.id,
        inp.bundleName, inp.product, deviceIds, ArrayList<String>(), out.p7bPath)
    if (p7b == "") {
        out.error = "⑥ ${provNote}"
        return out
    }
    out.add("⑥ profile：${provNote}")
    out.add("⑥ 落盘：${out.p7bPath}")
    // ⑥ 之后的**证书-配置一致性**自检（0.39.110 实测）：profile 里绑定的开发证书，必须是本地
    // `.cer` 里那张——证书以**云端为准**，本地 `.cer` 只是一份缓存。
    //
    // 现场（m3u8dl-tauri 真机）：复用云端同名证书（id=2080015801942840128）时本地 `.cer` 还是
    // **更早那张**（serial 63E51AD2…，11-01），hvigor 拿旧证书签、profile 里写新证书（63E51D71…，11-09）
    // → 设备回 `9568322 signature verification failed due to not trusted app source`。
    // 而登录 / 证书 / profile / 写回 / 装配每一环都报"成功"，只有真机装机这一下才炸。
    let (cerOK, cerNote) = ensureCerMatchesProfile(out, token, teamId, cert)
    out.add("⑥ ${cerNote}")
    if (!cerOK) {
        out.error = "⑥ ${cerNote}"
        return out
    }
    // ---------------- ⑦ 写 build-profile ----------------
    let (workKey, wkErr) = loadWorkKey(materialDirOfConfig(inp.configDir))
    if (wkErr != "") {
        out.error = "⑦ 读 material/ 失败：${wkErr}"
        return out
    }
    if (password == "") {
        // 复用旧 p12 时拿不到明文口令 → 只能沿用现有密文；没有现有密文就报错
        let (storePwd, keyPwd) = existingCiphertexts(inp.buildProfile)
        if (storePwd == "" || keyPwd == "") {
            out.error = "⑦ 复用现有 p12 但工程里没有可沿用的口令密文（删掉 p12 让它重新生成）"
            return out
        }
        let m = SigningMaterial()
        m.storeFile = out.p12Path
        m.certpath = out.cerPath
        m.profile = out.p7bPath
        m.storePassword = storePwd
        m.keyPassword = keyPwd
        return writeBack(out, inp, m)
    }
    let (storePwd, e1) = encryptPasswordHex(workKey, password)
    if (e1 != "") {
        out.error = "⑦ 加密 storePassword 失败：${e1}"
        return out
    }
    let (keyPwd, e2) = encryptPasswordHex(workKey, password)
    if (e2 != "") {
        out.error = "⑦ 加密 keyPassword 失败：${e2}"
        return out
    }
    let m = SigningMaterial()
    m.storeFile = out.p12Path
    m.certpath = out.cerPath
    m.profile = out.p7bPath
    m.storePassword = storePwd
    m.keyPassword = keyPwd
    return writeBack(out, inp, m)
}

/** 读现有 build-profile 里的两段口令密文（复用旧 p12 时沿用） */
func existingCiphertexts(buildProfile: String): (String, String) {
    if (buildProfile == "" || !exists(Path(buildProfile))) {
        return ("", "")
    }
    try {
        let m = signingMaterialOf(String.fromUtf8(File.readFrom(buildProfile)))
        return (m.storePassword, m.keyPassword)
    } catch (e: Exception) {
        let _ = e
        return ("", "")
    }
}

/** 把材料写回 build-profile.json5（先留 .bak） */
func writeBack(out: AutoSignOutcome, inp: AutoSignInput, m: SigningMaterial): AutoSignOutcome {
    if (inp.buildProfile == "" || !exists(Path(inp.buildProfile))) {
        out.error = "⑦ 找不到 build-profile.json5（${inp.buildProfile}）"
        return out
    }
    out.buildProfile = inp.buildProfile
    try {
        let origin = String.fromUtf8(File.readFrom(inp.buildProfile))
        // 已有配置：同一套材料（同一个 .p12）就地更新（.p7b/.cer 会因为证书换发而变）；
        // 别的材料一律不动，报错让人决定
        let (newText, err) = if (parseProjSigning(origin).hasSigningConfigs) {
            replaceOwnSigningConfigs(origin, m)
        } else {
            applySigningConfig(origin, m)
        }
        if (err != "") {
            out.error = "⑦ 写回失败：${err}"
            return out
        }
        let bak = "${inp.buildProfile}.lingqu-autosign.bak"
        File.writeTo(bak, origin.toArray())
        File.writeTo(inp.buildProfile, newText.toArray())
        out.backup = bak
        out.add("⑦ 已写回 signingConfigs（备份：${bak}）")
        out.ok = true
        return out
    } catch (e: Exception) {
        out.error = "⑦ 写盘失败：${e}"
        return out
    }
}

/** 第一个存在的环境变量值（路径类要验存在，见 AGENTS §4-38） */
func firstExistingEnv(names: Array<String>): String {
    for (n in names) {
        let v = envOf(n).trimAscii()
        if (v != "" && exists(Path(v))) {
            return v
        }
    }
    return ""
}

/**
 * 让本地 `.cer` 与刚下载的 profile 里的开发证书**是同一张**（证书以云端为准）。
 *
 * 判定与修复都落在这里：不一致时按 `certObjectId` 重下一次（旧文件改名留底），再核一次；
 * 重下仍不一致说明**云端那张证书不是当前 `.p12` 这把钥匙签的**，只能 `--newKeys`。
 */
func ensureCerMatchesProfile(out: AutoSignOutcome, token: AgcLoginOutcome, teamId: String,
    cert: AgcCert): (Bool, String) {
    var cerText = ""
    try {
        if (exists(Path(out.cerPath))) {
            cerText = String.fromUtf8(File.readFrom(out.cerPath))
        }
    } catch (e: Exception) {
        return (false, "读本地证书失败：${e}")
    }
    if (cerText == "") {
        return (false, "本地没有证书文件（${out.cerPath}）")
    }
    var devPem = ""
    try {
        if (exists(Path(out.p7bPath))) {
            devPem = profileDevCertPemOf(extractProfileJson(String.fromUtf8(File.readFrom(out.p7bPath))))
        }
    } catch (e: Exception) {
        let _ = e
        devPem = ""
    }
    if (devPem == "") {
        // 读不出就不拦：证书格式一变更不该让整条链全红（宁可真机那一步再说话）
        return (true, "profile 里读不出开发证书，跳过证书一致性自检")
    }
    if (cerHasCertOf(cerText, devPem)) {
        return (true, "本地 .cer 与 profile 是同一张开发证书")
    }
    let bak = "${out.cerPath}.lingqu-stale-${nowMs()}"
    try {
        File.writeTo(bak, cerText.toArray())
    } catch (e: Exception) {
        return (false, "备份旧证书失败：${e}")
    }
    let objectRef = if (cert.certObjectId != "") { cert.certObjectId } else { cert.id }
    let (saved, dlErr) = agcDownloadObject(token.accessToken, token.userId, teamId, objectRef,
        out.cerPath)
    if (dlErr != "") {
        return (false, "本地 .cer 是旧证书且重下失败（${dlErr}）——装到真机会被 9568322 拒")
    }
    var fresh = ""
    try {
        fresh = String.fromUtf8(File.readFrom(out.cerPath))
    } catch (e: Exception) {
        return (false, "重下后读不出证书：${e}")
    }
    if (!cerHasCertOf(fresh, devPem)) {
        return (false, "本地 .cer 与 profile 不是同一张证书，重下后仍不一致（旧文件已备份到 ${bak}）——" +
            "云端那张证书不是当前 .p12 这把钥匙签的，用 `sign --auto --newKeys` 重生成密钥对再签")
    }
    return (true, "本地 .cer 是旧证书，已按云端重下：${saved}")
}

/**
 * 抽出 PEM 文本里所有证书块并**规范化**（去掉换行与行内空白）。
 *
 * 同一张证书在不同文件里换行位置可能不同，直接字符串比较会假红；
 * 而 `.cer` 是一条链（实测顺序是 根 → 中间 → 开发者），所以只谈"链里有没有这张"，
 * 不假设开发者证书在第几位。
 */
public func pemCertBlocksOf(text: String): ArrayList<String> {
    let blocks = ArrayList<String>()
    let begin = "-----BEGIN CERTIFICATE-----"
    let endMark = "-----END CERTIFICATE-----"
    var from: Int64 = 0
    var go = true
    while (go) {
        match (text.indexOf(begin, from)) {
            case Some(s) =>
                match (text.indexOf(endMark, s + begin.size)) {
                    case Some(e) =>
                        let norm = squashWhitespaceOf(text[(s + begin.size)..e])
                        if (norm != "") {
                            blocks.add(norm)
                        }
                        from = e + endMark.size
                    case None => go = false
                }
            case None => go = false
        }
    }
    return blocks
}

/** 去掉所有空白字节（空格 / 制表 / LF / CR），用于证书正文比较 */
func squashWhitespaceOf(s: String): String {
    let bytes = s.toArray()
    let acc = ArrayList<Byte>()
    for (b in bytes) {
        if (b == 32 || b == 9 || b == 10 || b == 13) {
            continue
        }
        acc.add(b)
    }
    return String.fromUtf8(acc.toArray())
}

/**
 * 取 profile JSON 里 `bundle-info.development-certificate` 的证书**正文**（已规范化）；取不到给空串。
 *
 * 用"找键 → 找首个引号 → 扫到未转义引号"的写法而不是完整 JSON 解析：profile 里的证书是
 * **一行带 `\n` 转义的长 base64**。取值后必须**交回 `pemCertBlocksOf`**再解析一次，
 * 否则一边是链里的块体、一边是带 BEGIN/END 标记的整段，比较口径不一致会永远判"不是同一张"。
 */
public func profileDevCertPemOf(profileJson: String): String {
    let key = "\"development-certificate\""
    match (profileJson.indexOf(key)) {
        case Some(k) =>
            match (profileJson.indexOf("\"", k + key.size)) {
                case Some(q) =>
                    let bytes = profileJson.toArray()
                    let acc = ArrayList<Byte>()
                    var i = q + 1
                    var esc = false
                    while (i < bytes.size) {
                        let c = bytes[i]
                        if (esc) {
                            esc = false
                            // `\n` / `\r` / `\t` 还原成真空白；其余转义保留字符本身
                            if (c == 110) {
                                acc.add(10)
                            } else if (c == 114) {
                                acc.add(13)
                            } else if (c == 116) {
                                acc.add(9)
                            } else {
                                acc.add(c)
                            }
                        } else if (c == 92) {
                            esc = true
                        } else if (c == 34) {
                            break
                        } else {
                            acc.add(c)
                        }
                        i++
                    }
                    let blocks = pemCertBlocksOf(String.fromUtf8(acc.toArray()))
                    if (blocks.size == 0) {
                        return ""
                    }
                    return blocks[0]
                case None => return ""
            }
        case None => return ""
    }
}

/** 本地 `.cer`（证书链）里是否含这张证书（纯函数） */
public func cerHasCertOf(cerText: String, pem: String): Bool {
    if (pem == "") {
        return false
    }
    for (b in pemCertBlocksOf(cerText)) {
        if (b == pem) {
            return true
        }
    }
    return false
}

/** 临时目录（放 CSR 之类中间产物） */
func tempDirOf(): String {
    let t = firstNonEmptyEnv(["TEMP", "TMP"])
    if (t == "") {
        return "."
    }
    return t
}
