# iOS CDN 导入器（非越狱线）

把自建 CDN 目录里的 634 个归档**在设备本机**解压导入到游戏的沙盒资源目录，
让客户端启动时认为「资源已下载完成」，从而跳过官方 CDN 的 10.7GB 下载。

- 目标目录：`<容器>/Library/Application Support/com.leiting.wf/Local Store/asset/asset_download/dummy/`
  （`download/**` 放解压出来的资源，`info.json` 描述版本与规模）
- 交付形态：**一支注入游戏进程的 dylib**（`CdnImporter.dylib`）。非越狱设备上没有第二个进程能写进游戏的
  `Application Support`，所以导入器必须运行在游戏进程内；dylib 通过往 IPA 主二进制追加一条
  `LC_LOAD_DYLIB` + 重签侧载进入设备。
- 数据来源：**iOS 文件 App**（`UIDocumentPickerViewController`）。用户在文件 App 里选「文件夹」或「多个文件」，
  导入器拿到 security-scoped URL 后读取，归档本身留在 SMB / iCloud Drive / On My iPhone 原地，不占容器空间。

> 目录内容：ObjC 源码（`*.h` / `*.m`）+ 6 个 Node 工具（`tools/`，含 `tools/lib/`）+ 计划清单与生成表 + 非越狱注入器。
> 越狱注入线不在本仓库（本线**不使用** MobileSubstrate / Theos）。

## 1. 数据契约（634 归档 → 137,820 文件）

| 项目 | 值 |
| --- | --- |
| 基线段版本 | `1.4.0`（`full.archive[]`，`/asset/get_path` 快照） |
| 目标版本 | `1.4.54`（沿 `original_version → version` 逐级叠加 54 步 diff） |
| 归档数 | 634 = common 401（322 full + 79 diff）/ medium 218（164 + 54）/ ios 15（5 + 10） |
| 压缩态合计 | 10,748,428,364 字节 |
| 解压终态 | **137,820 个文件 / 10,191,161,030 字节**（= `info.json.totalSize`） |
| 解压顺序 | 严格按 `full.archive[]` 数组序 + diff 链顺序；**后解压的同名文件覆盖先解压的** |
| 跳过规则 | 条目名以 `/` 结尾（目录）、`.empty`、`.hash` 结尾的条目不解压 |
| 单条目校验 | 逐块累计 CRC32 与 zip 中央目录比对 |
| 归档校验 | 来源字节数必须等于计划字节数；可选深度 sha256（base64，与计划表比对） |

`info.json` 写入内容（客户端只读其中 `version` / `assetRecoveryInfo` / `totalSize` / `assetSizeKind` / `baseUrl`）：

```json
{
  "version": "1.4.54",
  "assetRecoveryInfo": [],
  "totalSize": 10191161030,
  "assetSizeKind": "fulfill",
  "baseUrl": "http://<自建服务器>/patch/cn/",
  "latestModifiedTimeOfArchive": "Sat, 09 Aug 2025 09:35:28 GMT"
}
```

导入成功后会删除 4 个标记文件：`<dummy>/{partial_downloaded.json,partial_downloaded.platform,partial_downloaded_android_thread.json}`
与 `<Local Store>/partial_downloaded.json`（客户端用它们判断「正在下载中」，留着会一票否决本地资源）。

### 1.1 客户端怎么利用这套文件（决定导入器「做到哪一步就够」）

客户端启动时走 `GlobalLoading.applyLoad(rightAfterSignUp, serverAssetVersion)`（`pinball/loading/global/GlobalLoading.as:392-432`），
三个判定的结果决定它走 ZIP 下载流 / Recovery 流 / 直接进游戏：

| 判定 | 依据 | 导入器要满足的条件 |
| --- | --- | --- |
| `isDownloaded()` | `partial_downloaded.json` 存在 ⇒ false；否则比 `info.json.version` 与服务器版本 | 删掉 4 个 partial + `version` 写成服务器当前版本（本项目 = `1.4.54`） |
| `isAssetComplete()` | `info.json.assetRecoveryInfo == []` | 写空数组（字段缺失会被判为不完整） |
| `needsDownloadAsset()` | iOS（`tutorialBundleKind.index == 1`）返回 `!isBeforeTutorialDownload()` | 与导入内容无关，教学进度正常推进即可 |

- 客户端另有一次 **sufficiency check**：下载服务端 `files_list`（当前是零字节的 `recovery/empty.csv`）逐行
  `fileExists(<dummy>/<path>)`，缺失项会写回 `assetRecoveryInfo` 并触发 Recovery 流（URL = `baseUrl + <hash>`）。
  导入完整时该表为空 ⇒ 这里不会拦。
- `totalSize` 只用于**空间检查**，`assetSizeKind` 决定下载模式（`fulfill`/`shortened`），`baseUrl`/`files_list`
  只服务 Recovery；`latestModifiedTimeOfArchive` 客户端只写不判。
- 因此导入器**只需**：按序铺好 `<dummy>/download/**` + 写 `info.json` + 删 4 个 partial。
  代价是每次启动客户端仍会向服务器要 `/asset/get_path` 之类的接口来拿「服务器版本」——所以要么跑本仓库的
  自建服务（`npm run dev` / `启动CN服-8001.bat`），要么用主项目/交付包里的改址脚本（`patch-ipa.mjs`，不在本仓库）把域名改到自建服务。

## 2. 构建（Windows 上编不了，必须 macOS）

### 2.1 走 CI（推荐）

`.github/workflows/ios-importer.yml`：`workflow_dispatch` 手动派发，或向 `ios/importer/**` push 时自动跑。

- `test` 作业：ObjC 静态自检 + `node tools/run-tests.cjs`（ZIP 解析护栏、计划一致性、注入器断言、lint 自身）。
- `build` 作业：用 iPhoneOS SDK 编译 `CdnImporter.dylib` → ad-hoc 签名 → 合成迷你 IPA 端到端冒烟注入 →
  产物上传 artifact（`CdnImporter-dylib` / `clang-log` / `injection-smoke`），同时把日志与产物推到
  `ci-diag/<run_id>` 一次性分支（只保留最近一条，新的一条推送时会自动删掉旧的），编译失败时把 clang
  错误按 `::error` 注解贴到运行页；成功时也会 emit `::notice`：`dylib-evidence`（架构/字节数/sha256）
  与 `inject-smoke`（注入断言条数）。**从运行页下载 `CdnImporter-dylib` artifact 即得可侧载的 dylib**。
- 同一次构建还会把 dylib 发到 **release 滚动标签 `cdn-importer-latest`**（`gh release upload --clobber`），
  因为 release 资产对公开仓库**匿名可取**，而 artifact 下载必须带 token。稳定直链：
  `https://github.com/NSDelta/wf-cdn-importer-iOS/releases/download/cdn-importer-latest/CdnImporter.dylib`
  （同目录还挂着 `clang.log` 与 `inject-report.json`）。
- **兜底通道（不依赖 release 写权限）**：同一次构建还会用同一个 token 把产物提交到一次性分支
  `cdn-artifacts/<run_id>`，`raw` 直链无需任何凭据即可下载，且 `run_id` 保证不会命中 CDN 缓存：
  ```
  https://raw.githubusercontent.com/NSDelta/wf-cdn-importer-iOS/cdn-artifacts/<run_id>/CdnImporter.dylib
  # 同分支：clang.log / inject-report.json / meta.txt（含 dylib 字节数与 sha256）
  ```
  该分支与 `ci-diag/*` 一样滚动清理（新的一次构建会删掉旧的），所以**取到就本地保存**。
  命令行取回（不需要 token、不需要 SSH 私钥）：
  ```bash
  curl -fLO https://raw.githubusercontent.com/NSDelta/wf-cdn-importer-iOS/cdn-artifacts/<run_id>/CdnImporter.dylib
  shasum -a 256 CdnImporter.dylib   # 与 meta.txt 里的 dylib_sha256 对照
  ```
  注：**SSH 密钥不能用来下载 artifact/release**——SSH 只对 `git` 传输生效，artifact 与 release 走 HTTPS
  API（artifact 必须带 token；release 与 `raw` 分支匿名可取）。
- 派发时可传 `patch_base`（写进 `info.json` 的 `baseUrl`；默认是 hygiene 占位地址 `http://192.168.1.10:8001/patch/cn/`，
  真实局域网地址只在派发参数里传，不要写进仓库文件）。

### 2.2 本地 Mac 手编

```bash
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK" -miphoneos-version-min=14.0 -fobjc-arc -O2 -Wall \
  -install_name @executable_path/Frameworks/CdnImporter.dylib \
  ios/importer/*.m \
  -framework UIKit -framework Foundation -framework UniformTypeIdentifiers -framework CoreGraphics -lz \
  -o CdnImporter.dylib
codesign --force --sign - CdnImporter.dylib
```

## 3. 部署到设备（三步）

```bash
# ① 服务器改址（可选但常用）：把官方域名改写到自建服务器。它自带硬断言「ncmds/sizeofcmds 不变」，
#    所以必须在注入之前跑。
# 改址脚本不在本仓库：先用它把游戏服务器地址改到自建服务（它断言 ncmds/sizeofcmds 不变），再注入 —— 顺序不能反
#    产出的中间包下面写作 step1.ipa（未改址就直接用官方 IPA 也行，只是游戏会连官方服务器）

# ② 注入导入器：追加 LC_LOAD_DYLIB + 把 dylib 放进 Payload/<App>.app/Frameworks/
node ios/importer/tools/inject-dylib.mjs --ipa step1.ipa --dylib CdnImporter.dylib --out step2.ipa
#    加 --dry-run 可只做断言不落盘（推荐先干跑一次看 16 条断言）

# ③ 侧载：Sideloadly（Windows 可用）拖入 step2.ipa，用你自己的 Apple ID 重签并安装。
#    它会连带重签嵌套 dylib。免费账号签名 7 天到期，重签是原地覆盖安装，游戏数据容器保留，
#    已导入的 10.19GB 资源**不需要重做**。
```

注入器做了什么、保证了什么（`tools/inject-dylib.mjs`，纯 Node，Windows 可跑）：

- 定位主二进制（`Payload/<App>.app/<App>`，找不到时读 `Info.plist` 的 `CFBundleExecutable` 兜底）。
- 在**命令区末尾**（`32 + sizeofcmds`）写入一条 `LC_LOAD_DYLIB`（`cmdsize` 8 字节对齐，34 字符 install name → 72 字节），
  `ncmds+1`、`sizeofcmds+72`；段与所有 section 的文件偏移/尺寸**一个都不动**。
- dylib 条目写入 `Payload/<App>.app/Frameworks/<install name 的基名>`（默认也就是 `CdnImporter.dylib`），mode `0755`，紧跟主二进制条目。
  **条目名跟 install name 对齐、不跟本地文件名对齐**：`--dylib` 传的是叫别的名字的文件也照样按 install name 命名，
  因为 dyld 是按 `LC_LOAD_DYLIB` 里的路径找库的（名字对不上，注入完的 IPA 一启动就 `Library not loaded`）；两者不一致时会打印一行提示。
- 落盘前 16 条断言（任一条失败就抛错、不写文件），关键几条：主二进制 `cryptid=0`、头部余量足够、
  **待写入的 72 字节原本全为 0**、文件长度不变、原有 load command 逐字节不变、所有 section 偏移不变、
  回读主二进制与 dylib 与内存一致、其余条目内容不变。报告写到 `<out>.build-report.json`。
- 幂等：对已注入过的 IPA 再跑一次不会重复写命令、不会重复加条目。

## 4. 在设备上使用

1. 先把 634 个归档准备好并送到设备可访问的位置（见第 5 节）。
2. 进游戏（导入器随进程加载，屏幕边缘会出现一个蓝色悬浮球「CDN」；拖动可换位置，位置记在 `NSUserDefaults`。
   默认贴右边；若检测到别的悬浮插件（见 4.1）则默认贴左边，并挂在**同层**）。
   **资源已经完整时球不会出现**（导过一次之后就会这样）：判据与客户端 `isDownloaded()` / `isAssetComplete()`
   同口径 —— `info.json` 版本 = 1.4.54、`assetRecoveryInfo` 为空、4 个 partial 都不在、`download/` 存在。
   想再导入就删掉 `info.json`，或把 `NSUserDefaults` 的 `CdnImporterForceBall` 设为 `YES` 强制显示；
   导入成功后球也会自动收起来（关掉面板那一刻），别误判成「注入失败」。
3. 点球打开面板 → **选文件夹**（推荐，一次授权整棵子树）或**选文件**。
   **每次选择都是「追加」**：iOS 的「文件」App 常常不给多选，所以可以一个一个加、也可以分几次把
   六个归档目录分别选进来，列表会累积（按路径自动去重，重复选同一个不会加两遍）。
   每加一项日志会给出体检结论：`✓ 计划内`（显示层/kind/字节数）、`⚠️ 字节数不符`、`？基名不在计划里`。
   加错了用 **撤销上次**（只回滚最近一批）或 **清空选择**。
   面板状态区会实时显示「按名字对上计划：N / 634（还缺 M 个 zip）」——**注意这只是按名字的快速体检，
   权威识别以预检为准**（tar 分卷的成员、改名包、整包 zip 都要预检时才解析）。
4. 点**预检**：只做索引与匹配，不动任何文件；会列出「识别到的归档数 / 缺失清单 / 目标目录现状 / 可用空间」。
   预检若报「缺失 M 个归档」，按缺的基名补齐后再预检，直到「识别 634 / 缺失 0」。
   面板另有 **深度校验(开/关)**（切到「开」后每个归档会整包比一遍 sha256，导入时间约翻倍，见第 6 节）
   与 **导出日志**（三条腿：整份日志进剪贴板、写一份到 `<容器>/Documents/CdnImporter.log`、再弹分享面板，见第 7 节）两个按钮。
5. 确认无误后点**开始导入**并保持游戏在前台（面板会自动禁用息屏）。进度条显示归档进度、已写文件数、
   压缩态已读字节与预估剩余时间；导入期间可**取消**（取消保留 partial 标记，游戏下次会自己走下载流）。
6. 完成后面板显示终态统计。若显示 `137820 个文件 / 10191161030 字节` 即与权威终态完全一致；
   随后**重启游戏**（本工具不 hook 客户端启动逻辑，重启后客户端读 `info.json` 判定资源已就绪）。
   导入成功后悬浮球会自动收起来（关掉面板那一刻就收）——这正是「资源已完整」的旁证。

> 输入列表只活在**本次游戏运行**里：游戏被杀掉/重启后要重新选（列表不落盘）。
> 好处是不会因为上一次选漏了而悄悄沿用旧列表。

### 4.1 与别的悬浮插件共存（同层规则）

同一个进程里可能同时挂着别的悬浮插件的覆盖窗口，
`windowLevel = UIWindowLevelStatusBar + 100`，球是右上角 52×52 的 Button，
`accessibilityLabel = @"SpLogin 服务器绑定"`）。两家各建一个全屏透明窗口时，
**等级高的一方会把自己的球压在对方球身上**，对方那颗球就点不动了（表现为「另一个插件没法用了」），
所以定成两条规则：

| 情况 | 我们怎么做 |
| --- | --- |
| 发现对方的悬浮层窗口（未 `hidden`、等级在 `UIWindowLevelNormal` 与 `UIWindowLevelAlert` 之间、窗口/根 VC/根视图类名含 `Overlay`/`SpLogin`/`Floating`/`Ball`/`Pass`） | **把球挂进对方的窗口**（真·同一图层），默认落在**左边**；与对方的球重叠时自动让到左侧、再不行让到对方下方；我们自己的窗口这时整体 `hidden`，不留多余的透明窗口 |
| 对方窗口不在（登录插件的出货配置是「进游戏后整套覆盖层停用」） | 才用我们自己的窗口，等级 `UIWindowLevelStatusBar + 90`（=1090），**仍低于**对方的悬浮层，任何时候都不抢它们的层 |

识别对方的球优先用 `accessibilityLabel = @"SpLogin 服务器绑定"`（现成、稳定的标志），认不到才退化成
「尺寸 36–88pt 的方形子视图」。看门狗每 2s 复查一次宿主，`UIWindowDidBecomeKeyNotification` /
`UIWindowDidBecomeVisibleNotification` / `UIWindowDidBecomeHiddenNotification` 也会立即复查，
所以两边的覆盖层来回起落都能在 2s 内切换宿主。日志里写清当前宿主：
`宿主=SpLoginPassView（同层，lvl=1100）` 或 `宿主=自己的窗口 lvl=1090`；重叠避让也会各写一行。

## 5. 怎么把资源送到设备

| 途径 | 做法 | 备注 |
| --- | --- | --- |
| SMB / NAS（推荐） | 文件 App → 连接服务器 → 挂载共享，把 CDN 归档目录共享出去 | 归档原地读取，容器只占解压后的 10.19GB |
| iCloud Drive | 把归档拖进 iCloud Drive（需 10.7GB 云空间，或只拷一部分） | 逐卷传输，可分批导入 |
| On My iPhone | 用「文件」App 从电脑拷进设备本地 | 设备本地要腾出 10.7GB + 10.19GB |
| tar 分卷 | `node ios/importer/tools/build-tar.mjs --cdn <你的 cdn 目录> --out ./cdn-tar --volume-bytes 2000000000` | 把 634 个 zip 打成分卷 tar，传输时只需几个文件；导入器支持 `.tar` 与 `.tar.part.NN` |
| 整包 zip | 把若干归档再套一层 zip | 导入器会把内层 zip 当输入（stored 直接取窗口，deflate 先物化到临时文件） |

导入器按**基名**认领归档，所以归档放在哪个子目录、外层包了几层都不影响；
基名不命中时会尝试「按字节数唯一命中」的兜底认领，并在日志里记明。
因为选择是追加式的，**六个归档目录可以分六次「选文件夹」加进来**（或把 CDN 目录
整个共享出来一次选完），不必强求一次选中所有归档。

若手上已有 Android 的 `cn-cdn.tar.part.00…05`（约 10.88GB，677 个归档），它包含 common + medium 层，
可覆盖本计划的 619/634 个归档；另有 iOS 的 `ios-cdn.tar.part.00…05`（约 10.75GB）覆盖全部 634 个。
缺的归档必须补齐后重新预检：导入器是**严格模式**（缺任一归档就不动目标目录、不写 `info.json`，
错误码 `MissingArchives`），面板上没有「允许缺包继续」开关（`CdnImportEngine.allowMissingArchives`
默认 `NO` 且未暴露到 UI）。

## 6. 失败与校验

- **空间预检**：要求可用空间 ≥ `10,191,161,030 + 1GB`，不足直接拒绝，不动任何文件。
- **缺归档**：默认严格模式 —— 有任一归档未识别就不动目标目录，只报出缺失清单（错误码 `MissingArchives`，
  `NSError.userInfo` 里带最多 50 条明细）。可在面板上改用「允许缺包继续」。
- **顺序覆盖**：始终按计划顺序解压（不是按用户选择顺序），保证「后覆盖先」的语义正确。
- **覆盖统计**：内部按「相对路径 → 已写字节」记账，覆盖同名文件时用 `新 - 旧` 修正终态总量，
  因此 `totalsMatch` 能真实反映终态是否等于权威值。
- **条目级校验**：每个条目解压时逐块累计 CRC32，与 zip 中央目录比对；不符即中止且**不写 `info.json`**。
- **深度校验**（面板开关 / `NSUserDefaults` 键 `CdnImporterDeepVerify`）：额外把整个归档文件的
  sha256（base64）与计划表比对，代价是每个归档多读一遍（10.7GB）。
- **zip-slip 防护**：条目名净化，拒绝绝对路径、`..`、`:`，写盘路径必须落在 `<dummy>/download/` 之内。
- **半成品清理**：解压失败会删掉失败条目的半成品文件；成功的归档则保留（可断点重来）。

## 7. 日志与排查

- 日志文件：`<容器>/Library/Application Support/CdnImporter/CdnImporter.log`（同一份内容也走 `NSLog`，
  可用 `idevicesyslog` 或 Xcode 看）。超过 4MB 轮转为 `.log.1`。
- 面板右侧就是实时日志。点**导出日志**会同时做三件事，任何一条成功都能把日志拿出来：
  ① 整份日志写进**剪贴板**（最后 512KB）——在游戏的聊天/公告等任意输入框长按「粘贴」即可发出来（最稳）；
  ② 复制一份到 `<容器>/Documents/CdnImporter.log`（固定落点，日志里会打印完整路径）；
  ③ 弹系统**分享面板**（AirDrop 到 Mac / 存进「文件」App），由当前最上层窗口的 rootViewController 弹出。
  分享面板拿不到窗口时日志里会写「没有可用的窗口来弹分享面板」，此时用 ① 或 ②。
- 常见问题：
  - 「没识别到任何归档」：确认选的是**文件夹**（不要选到只有外层压缩包的父目录）或直接选 zip/tar 文件；
    若归档被重命名过，看日志里是否有「按字节数认领」记录。
  - 加了几项后状态区显示「还缺 M 个 zip」：正常（追加式选择就是一个个加），继续加到 634 或直接预检；
    tar 分卷不参与这个按名字的计数，会统一显示「tar N 项」。
  - 「这一批全是已加过的」：同一路径重复选会被去重忽略（不会出错）；想重选就先「撤销上次」或「清空选择」。
  - 「识别到的归档数少于 634」：预检里会列出缺失基名，补齐后重新预检。
  - 导入中断后游戏开始下载：说明 partial 标记还在（取消是合法的），删掉 4 个 partial 或重新完成一次导入。
  - 悬浮球不出现：确认 dylib 注入成功（`otool -l worldflipper | grep -A2 LC_LOAD_DYLIB` 应能看到
    `@executable_path/Frameworks/CdnImporter.dylib`）且已被重签。**先排除「资源已完整所以收起来了」**
    （面板日志里会有「资源已完整（…），收起悬浮球」，此时删掉 `info.json` 或置 `CdnImporterForceBall=YES` 即可找回）。
  - 「失败：无法读取磁盘可用空间（…）」：这条报错在 v1.3 已修 —— 「清空目标目录」会把目录本身删掉，
    而 `attributesOfFileSystemForPath:` 对不存在的路径会直接报错，所以现在先重建目录再检查，并且检查前
    会向上找最近的已存在目录（日志里会写「注意：… 不存在，按最近的已存在目录统计可用空间：…」）。
  - 两个悬浮球里只有一个点得动 / 登录插件的球被压住：见 4.1。日志里搜 `宿主=` 与 `重叠`，
    若一直写「自己的窗口」说明没认出对方的悬浮层（对方窗口可能还没建：等 2s 看门狗复查，或看它的日志）。
  - 「读 … 失败(off=…): Bad address」（v1.4 已修）：`EFAULT` 是两种原因的同一张面孔 ——
    ① 解压长循环里攒下的 autoreleased 分块把内存顶到上限，缓冲区根本没拿到（`dataWithLength:` 返回 nil 时
    `mutableBytes` 就是 NULL，把 NULL 交给 `pread` 就是「Bad address」）；② 分卷放在「文件」App 的
    iCloud / File Provider 位置，本地副本被系统回收后，长时间开着的 fd 读不到内容。
    v1.4 的对策：逐条目 `@autoreleasepool`（分配失败会如实报「内存不足：…」）、遇到 `EFAULT/EIO/ESTALE`
    按路径重开文件重试 3 次（日志里会写「按路径重开文件后重试」）。
    为躲开②：**别把分卷放在 iCloud Drive**，复制到「我的 iPhone」本地目录（或直接用 SMB 连电脑），
    并尽量把 6 卷的选择、预检、导入放在同一次前台运行里做完。
  - 判断内存是不是瓶颈：每条归档收尾那行日志末尾有「内存 X」（`phys_footprint`，就是 jetsam 的判据）。
    正常情况它应该一路平稳；若在导入过程中持续爬升到几百 MB 以上，说明还有没排空的自动释放对象。

## 8. 自检与测试

```bash
node ios/importer/tools/lint-objc.mjs --stats      # ObjC 静态自检（括号/@interface↔@end 配对/声明↔实现）
node ios/importer/tools/verify-plan.mjs --sha256   # 计划 vs 本地 CDN 全量核对（缺失/字节数/sha256/实体表对账）
node ios/importer/tools/verify-plan.mjs --emit     # 重新生成 CdnImportPlan.generated.{h,m} 与 wanted-archives-ios.txt
node tools/run-tests.cjs                            # 4 个测试文件（ZIP 护栏 / 计划一致性 / 静态自检 / 注入器）
```

`verify-plan.mjs` 支持 `--cdn <归档目录>` / `--snapshot <path 快照>` / `--entities <csv>`；
对着本地 CDN 目录核对的结果：缺失 0 / 字节数不符 0 / sha256 不符 0 / 实体表对账 0 差异。
**改了 `tools/plan-lib.mjs` 之后必须重跑 `--emit`**，否则生成表与工具会漂移（`ios_importer_plan.test.cjs` 会拦住）。

## 9. 已知限制

- 不 hook 客户端原生/AS3 的下载流程（`AssetDownloadAne`、`GlobalLoading`）：本工具只负责「把文件铺好 + 写
  `info.json` + 清 partial」，导入完成后需要**重启游戏**让客户端重新判定。
- 导入必须前台执行（10.19GB 写入，后台会被系统挂起）。
- 免费开发者账号 7 天重签一次；重签不丢数据。
- 目标目录名 `dummy` 是从 Android 参考实现与主项目的客户端消费流程文档得到的；**这个子目录是客户端开始联网
  下载资源时才创建的**，所以游戏还没跑过资源下载的手机上它不存在。导入器按下面的顺序探测（进程内只解析一次）：
  ① 某子目录含 `info.json` 或 `download/`（客户端正在用它）→ 采用并记日志；
  ② 某子目录含 `partial_downloaded*`（已开始下载、还没解压）→ 采用；
  ③ `asset_download` 下只有一个子目录（游戏建过，哪怕还空着）→ 采用；
  ④ 以上都没有 → 回退 `dummy`，并在面板把该行标成「**[推断]**」（①②③ 标「[已确证]」）。
  要消除这最后一点不确定性：**先让游戏跑一次资源检查/下载（几秒即可，让它把目录建出来）再导入**。
  也可用 `NSUserDefaults` 键 `CdnImporterStorageRoot` 覆写根目录。
- 越狱机不需要本线（越狱线的 MobileSubstrate 注入不在本仓库）。
- 输入列表（追加式选择的结果）只存在于**本次进程内**，不落盘：游戏重启后要重新选。面板在选每一项时就会
  `startAccessingSecurityScopedResource` 并在「撤销上次 / 清空选择」时归还，所以分多批加进来的目录在
  预检与导入时都还能读；但也正因为如此，**不要在多批选择之间杀掉游戏**。
- 「同层共存」（4.1）靠两条约定认对方：窗口等级落在 `UIWindowLevelNormal` 与 `UIWindowLevelAlert` 之间，
  且窗口/根 VC/根视图类名含 `Overlay`/`SpLogin`/`Floating`/`Ball`/`Pass`。以后若有第三个悬浮插件既不用
  这些命名、又把等级压到 `StatusBar + 90` 以下，我们不会识别它（但也不会抢它的层：我们自己的窗口只在
  等级更低的对方不存在时才显示，且只到 1090）。
- 资源完整时**默认不显示悬浮球**（用户要求：资源齐了就别再挡着屏幕）。三条复查路径保证它会自己回来：
  装好窗口时、看门狗每 ≈30s、App 回到前台、以及关面板时；判据只看 `info.json` + 4 个 partial 的存在性，
  不扫 137,820 个文件（那是 10GB 级 IO，不能每 30s 做一次）。所以要「强行再导一次」只有两个办法：
  删掉 `info.json`，或把 `NSUserDefaults` 的 `CdnImporterForceBall` 设为 `YES`。
- 长循环的内存纪律（v1.4）：解压是唯一的长循环（十几万条目 × 256KB 读取），每个条目都套
  `@autoreleasepool`；`CdnSHA256Base64OfSource`（深度校验读 10.7GB）按 1MB 分块排空。自检里有规则
  盯着这件事（`lint-objc.mjs`：调用 `extractEntry:` 却不含 `@autoreleasepool` 直接报错），
  防止以后改动时把池弄丢。
- 输入源的读取容错（v1.4）：`CdnFileSource` 遇到 `EFAULT/EIO/ESTALE` 会按路径重开文件重试 3 次
  （每次间隔 300ms，给 File Provider 把内容放回来的时间），仍然失败就带着「Bad address」的提示中止。
  中止时不写 `info.json`、保留 4 个 partial（客户端照旧认为资源没下完），已解开的文件留在原地等下次覆盖。
- tar 分卷必须**六个卷都在同一次运行里选进来**（`CdnConcatSource` 按 `.part.NN` 番号拼流）；
  分卷放在 iCloud Drive 上有被系统回收本地副本的风险，本机目录 / SMB 更稳。

## 10. 文件清单

| 文件 | 作用 |
| --- | --- |
| `CdnImporterConfig.{h,m}` | 构建期宏、NSUserDefaults 键、错误与错误码、日志、路径解析、JSON 读写、条目名净化、资源完整度判断 |
| `CdnArchiveSource.{h,m}` | 随机访问抽象（文件 / 内存 / 多源拼接 / 子窗口）+ 定长读 + sha256(base64) |
| `CdnZipArchive.{h,m}` | zip 中央目录解析（含 ZIP64）、流式 inflate + CRC32、条目物化 |
| `CdnTarIndex.{h,m}` | tar / tar 分卷成员索引（只读头，不解压；支持 GNU 长名与 pax） |
| `CdnImportPlan.{h,m}` + `CdnImportPlan.generated.{h,m}` | 634 条计划表（编译进 dylib）、按基名/字节数检索、权威终态常量 |
| `CdnArchiveIndex.{h,m}` | 把用户选择的输入识别成「计划基名 → 归档句柄」（散装 zip / tar 成员 / 整包 zip 成员） |
| `CdnImportEngine.{h,m}` | 四阶段导入：索引 → 缺包检查 → 按计划顺序解压 → 写 `info.json` + 清 partial |
| `CdnImporterOverlay.{h,m}` | 穿透式覆盖窗口 + 可拖动悬浮球 + 保活看门狗 + 与别的悬浮插件同层共存（4.1）+ 资源完整时自动收球 |
| `CdnImporterPanelViewController.{h,m}` | 面板 UI：选文件夹/选文件（追加式，带去重与撤销/清空）/预检/开始/取消/关闭/深度校验开关/导出日志（三条腿） |
| `CdnImporterEntry.m` | `__attribute__((constructor))` 入口（非越狱线没有 MobileSubstrate 的 `%ctor`） |
| `tools/verify-plan.mjs` + `tools/plan-lib.mjs` | 计划推导/核对/生成（Node，跨平台） |
| `tools/inject-dylib.mjs` | 非越狱注入器（LC_LOAD_DYLIB + dylib 入 bundle，16 条断言） |
| `tools/make-mini-ipa.mjs` | 合成迷你 IPA（CI 冒烟与测试用，不依赖官方包） |
| `tools/build-tar.mjs` | 把归档打成分卷 tar（便于传输），自带回读校验 |
| `tools/lint-objc.mjs` | ObjC 静态自检 |
| `tools/lib/zip-ipa.mjs` + `tools/lib/ios-macho.mjs` | ZIP 与 Mach-O 的最小实现（被注入器与迷你 IPA 生成器 import，本仓库自带，不依赖其它工程） |
| `assets/wanted-archives-ios.txt` | 634 行计划清单（人读用；设备侧读的是编译进 dylib 的 C 表） |
