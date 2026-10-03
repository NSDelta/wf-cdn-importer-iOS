# wf-cdn-importer-iOS

《World Flipper》（弹射世界）**国服 iOS 1.8.4** 的资源导入器 —— **不用越狱**。

它做的事一句话就说完：**把官方 CDN 的资源提前解压到游戏沙盒里，再留一张「资源已下载完成」的回执；游戏一启动就以为资源齐了，不再联网下载那 9.5 GB。**

---

## 它是怎么做到的

往官方 IPA 里注入一个小动态库 `CdnImporter.dylib`，让它跟着游戏一起跑。进游戏后沙盒里会多一个**悬浮球**，点开是导入面板；你把归档包交给它（原始 zip、tar 分卷、整包 zip 都认），它就按**正确的先后顺序**把 634 个归档解开，落到游戏自己用的资源目录：

```
<容器>/Library/Application Support/<app id>/Local Store/asset/asset_download/<子目录>/download/
```

最后写一份 `info.json`、删掉 4 个 `partial_downloaded*` —— 客户端的「资源完整」判定就是看这几样东西，于是它不再下载。

国服那个 `<app id>` 是 `com.leiting.wf`，但你不用管它：**导入器不要求任何固定的 bundle id / app id**，`Local Store` 是按磁盘痕迹认出来的（哪个目录里已经有游戏留下的 `asset/asset_download`，就用哪个）；注入器也不认包名，主二进制是按 `Payload/<X>.app/<X>` 自动找的。换签名、换包名（比如 AIR 的 app id 与 `Info.plist` 不一致）都照常工作。

### 三件它「不做」的事

* **不越狱**：没有 MobileSubstrate，不 hook 任何方法，不做方法交换。它只是一个构造函数 + 一个悬浮球 + 一堆文件读写。
* **不碰客户端的下载链路**：不改网络、不拦下载、不假装自己是服务器；它只是抢先把文件放到该在的位置。
* **不联网**：解压和校验全在手机本地完成（只有游戏自己连你的服务器时才需要局域网）。

> 仓库里**不含**游戏本体、IPA 和任何 CDN 数据 —— 需要你自备正版客户端和自己的 CDN 归档。

---

## 仓库里有什么

```
ios/importer/          导入器本体（Objective-C，21 个文件）
  ├── CdnImporterEntry.m            入口：构造函数 + 启动通知 + 定时兜底
  ├── CdnImporterConfig.{h,m}       路径、日志、目标目录探测、资源完整度判定
  ├── CdnImporterOverlay.{h,m}      悬浮球（能和别的悬浮插件同层共存）
  ├── CdnImporterPanelViewController.{h,m}   面板：选输入 / 预检 / 导入 / 日志
  ├── CdnArchiveSource.{h,m}        读取源：文件 / 内存 / 拼接 / 子区间
  ├── CdnZipArchive.{h,m}           ZIP 中央目录解析 + 流式解压（逐条目 CRC32）
  ├── CdnTarIndex.{h,m}             tar 与 tar 分卷索引
  ├── CdnArchiveIndex.{h,m}         归档识别（名字 + 字节数 + sha256）
  ├── CdnImportPlan{,.generated}.{h,m}   计划与 634 条有序表（generated 是生成物，别手改）
  ├── CdnImportEngine.{h,m}         引擎：索引 → 预检 → 解压 → 收尾
  ├── assets/wanted-archives-ios.txt   634 个归档清单（给人看的）
  ├── tools/*.mjs                   6 个纯 Node 工具（注入、打包、校验计划、静态自检……）
  └── README.md                     实现细节文档
tools/                 测试（node:test，无框架依赖）与测试运行器 run-tests.cjs
docs/                  使用说明 / 注入说明 / 验收清单
.github/workflows/     CI：在 macOS 上编译 dylib、冒烟注入、发到 release
```

---

## 怎么用

### 第 1 步：拿到 `CdnImporter.dylib`

最省事的是直接下 CI 发出来的 release（公开仓库，不用登录）：

```
https://github.com/NSDelta/wf-cdn-importer-iOS/releases/download/cdn-importer-latest/CdnImporter.dylib
```

也可以去 Actions 的 artifact 里拿（**要登录**），或者自己编（见下面「CI」那节的编译命令）。

### 第 2 步：注入到 IPA

如果要让游戏连你自己的服务器，先用 [IPApatcher](https://github.com/dennis96292/startpoint-cn-launcher/blob/main/tools/patch-ipa.mjs) 把服务器地址改掉（这一步必须在注入之前做），然后：

```bash
node ios/importer/tools/inject-dylib.mjs \
  --ipa   /path/to/official.ipa \
  --dylib ./CdnImporter.dylib \
  --out   ./patched.ipa
```

注入器会先断言 16 条不变量（`ncmds` 只 +1、`sizeofcmds` 只 +72、所有 section 的偏移和大小不变、命令区余量够、条目不冲突、写进去的 dylib 回读 sha256 一致……），任何一条不过就**不写输出文件**，不会产出一个装上去会崩的包。同一个 IPA 重复注入也没事，会直接报 `skipped: existing-load-command`。

> dylib 在包里的路径固定是 `@executable_path/Frameworks/CdnImporter.dylib`，条目名是从这条加载命令推出来的 —— 你本地文件叫什么都无所谓。

### 第 3 步：侧载，然后在手机上导入

用 Sideloadly / AltStore 重签侧载 `patched.ipa`（免费 Apple ID 是 7 天有效期；**重签是原地升级，已经导入的资源不会丢**）。进游戏后：

1. 点悬浮球 → **选文件夹** / **选文件**。追加式的：归档可以分好几次一项项加进来，按路径去重，加错了能「撤销上次」或「清空选择」。
2. 点 **预检**（只读，不写盘），确认面板显示 `识别 634/634，缺 0`。
3. 点 **开始导入**，让游戏留在前台（可以取消；取消后已导入的部分保留，重跑会先清空再来）。
4. 跑完应该是 `137820 个文件 / 10191161030 字节`，日志里能看到写 `info.json`、删 4 个 partial。
5. 杀掉游戏重开 —— 它不再下载资源。

更细的步骤和排查见 [`ios/importer/README.md`](ios/importer/README.md) 与 [`docs/使用说明.md`](docs/使用说明.md)。

---

## 数据契约（要和客户端对得上）

| 项目 | 值 |
| --- | --- |
| 目标版本 | CDN `1.4.54`（快照 `1.4.0` + 54 步 diff） |
| 归档数 | **634** = common 401 + medium 218 + ios 15（`archive-{common,medium,ios}-{full,diff}` 六个目录） |
| 压缩态合计 | 10,748,428,364 B（约 10.01 GiB） |
| 解开后 | **137,820 个文件 / 10,191,161,030 B**（约 9.49 GiB） |
| 落盘位置 | `…/asset_download/<子目录>/download/<条目名>`（条目名就是资源 hash，没有扩展名） |
| 跳过的条目 | 以 `/` 结尾的目录项、`*.empty`、`*.hash` |
| 覆盖语义 | **后写的覆盖先写的** —— 所以必须按计划顺序解压（快照在前，diff 按 `original_version → version` 串成链在后），顺序由 `CdnImportPlan.generated.m` 固定 |
| 收尾文件 | `info.json`：`version 1.4.54`、`assetRecoveryInfo []`、`totalSize 10191161030`、`assetSizeKind fulfill` |
| 平台层 | Android 的 `archive-android-*` **不参与**（iOS 只用 common + medium + ios） |

校验强度：默认按名字认出归档 + 核对每个归档的字节数 + **逐条目校验 CRC32**（不额外读盘）；面板上打开「深度校验」会再加一道整包 sha256（要读第二遍，耗时约翻倍）。

---

## 测试与自检

```bash
node tools/run-tests.cjs                 # 4 个测试文件：ZIP 解析护栏 / 计划一致性 / 静态自检 / 注入器
node tools/run-tests.cjs --filter inject # 只跑文件名里带 inject 的
node tools/run-tests.cjs --list          # 看会跑哪些文件

node ios/importer/tools/lint-objc.mjs --stats   # ObjC 静态自检
```

`lint-objc.mjs` 拦的都是那种「本机是 Windows、编不了 ObjC，只能等 CI 才发现」的低级错误：跨类访问私有 ivar、给 `UIViewController` 发它没有的 selector、头文件 import 闭包不全、长循环里忘了 `@autoreleasepool`、读磁盘空间前没先找已存在的目录、悬浮球窗口等级压过别的插件……每条规则都有对应的测试用例。

想不开设备就复核一遍计划和终态（对着你本地的 CDN 目录）：

```bash
node ios/importer/tools/verify-plan.mjs --cdn <你的 cdn 目录> --quiet
# 想连 sha256 一起比（要读完 10.7 GB，慢）：把 --quiet 换成 --sha256
```

---

## CI

`.github/workflows/ios-importer.yml`，push 到 `ios/importer/**`、`tools/**` 或手动派发时跑：

* **test**：静态自检 + 单元测试；
* **build**（macOS runner）：用下面这条命令编出 `CdnImporter.dylib`

```bash
xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK" -miphoneos-version-min=14.0 \
  -fobjc-arc -O2 -Wall \
  -DCDN_IMPORT_PATCH_BASE=@"http://192.168.1.10:8001/patch/cn/" \
  -install_name @executable_path/Frameworks/CdnImporter.dylib \
  ios/importer/*.m \
  -framework UIKit -framework Foundation -framework UniformTypeIdentifiers \
  -framework CoreGraphics -lz -o CdnImporter.dylib
```

编完还会：ad-hoc 签名 → 合成一个迷你 IPA 端到端跑一遍注入器并断言 → 三条「不需要 token 也能拿」的诊断通道（运行页注解 / `ci-diag/<run_id>` 分支 / artifact）→ 把 dylib 发到滚动 release → 再兜底推一条 `cdn-artifacts/<run_id>` 分支（raw 直链匿名可取，适合手上没有 token 的时候）。

### 关于 `baseUrl`

dylib 里内嵌的 `baseUrl` **只写进 `info.json`**，而客户端只有在「资源恢复（Recovery）」时才会用它。我们写的是 `assetRecoveryInfo: []`，服务器那边的 `files_list` 也是空表 —— Recovery 永远不会被触发，所以占位地址不影响任何功能。真想要真实值有两条路：手动派发 workflow 时填 `patch_base`，或者运行期设 `NSUserDefaults` 的 `CdnImporterPatchBase`。

改**游戏连的服务器地址**是另一码事（不在本仓库，由主项目/交付包里的改址脚本做），记得要在注入之前应用。

---

## 文档索引

| 文件 | 内容 |
| --- | --- |
| [`ios/importer/README.md`](ios/importer/README.md) | 实现细节：数据契约、客户端怎么消费、编译与部署、设备上的步骤、失败语义、日志排查、已知限制 |
| [`docs/使用说明.md`](docs/使用说明.md) | 使用者视角：资源从哪来、五种送到手机里的办法、设备上怎么导入、终态怎么核对、常见问题 |
| [`docs/注入说明.md`](docs/注入说明.md) | dylib 是什么、编译命令、三步注入、换服务器地址的三种情况、出问题怎么回退 |
| [`docs/验收清单.md`](docs/验收清单.md) | 真机逐项验收清单（A 包与环境 → J 记录表），带通过 / 有条件通过 / 不通过的判定口径 |
| [`ios/importer/assets/wanted-archives-ios.txt`](ios/importer/assets/wanted-archives-ios.txt) | 634 个归档的人读清单（设备侧读的是编译进 dylib 的表） |

## 许可

GPLv3（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）。

仅供自建服务器、离线备份与逆向研究使用；请自备正版客户端与自己的 CDN 数据，不要分发游戏资源。
