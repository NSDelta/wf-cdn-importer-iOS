# wf-cdn-importer-iOS

《World Flipper》（弹射世界）国服 iOS 1.8.4 的资源导入器，非越狱实现。

把 `CdnImporter.dylib` 注入官方 IPA 后，dylib 随游戏进程启动，在沙盒内提供悬浮球界面。向它提供 CDN 归档包（原始 zip、tar、tar 分卷、整包 zip），它按计划顺序解压 634 个归档到游戏资源目录，写入 `info.json`，删除 4 个 `partial_downloaded*` 文件。客户端启动时判定资源完整，跳过约 9.5 GB 联网下载。

目标路径：

```
<容器>/Library/Application Support/<app id>/Local Store/asset/asset_download/<子目录>/download/
```

`<app id>` 不是硬编码：`Local Store` 按磁盘上的现有痕迹判定（含 `asset/asset_download` 的目录优先，其次看 `info.json`、`download/`、`partial_downloaded*`）。注入器同样不依赖包名，主二进制按 `Payload/<X>.app/<X>` 探测，目录名与可执行文件名不一致时回退到 `Info.plist` 的 `CFBundleExecutable`。

## 实现约束

* **非越狱**：不使用 MobileSubstrate，不 hook / swizzle 任何方法。全部实现是一个 `__attribute__((constructor))`、一个悬浮球窗口和文件读写。
* **不介入客户端下载链路**：不改网络配置，不拦截下载请求，不模拟服务端；只负责提前写入文件。
* **不联网**：解压与校验在设备本地完成。

仓库不包含游戏本体、IPA 与 CDN 数据，需自备正版客户端与 CDN 归档。

## 目录结构

```
ios/importer/          导入器本体（Objective-C，21 个文件）
  ├── CdnImporterEntry.m            入口：构造函数 + 启动通知 + 定时兜底
  ├── CdnImporterConfig.{h,m}       路径、日志、目标目录探测、资源完整度判定
  ├── CdnImporterOverlay.{h,m}      悬浮球窗口（与其它悬浮插件同层共存）
  ├── CdnImporterPanelViewController.{h,m}   面板：选择输入 / 预检 / 导入 / 日志
  ├── CdnArchiveSource.{h,m}        读取源：文件 / 内存 / 拼接 / 子区间
  ├── CdnZipArchive.{h,m}           ZIP 中央目录解析与流式解压（逐条目 CRC32）
  ├── CdnTarIndex.{h,m}             tar 与 tar 分卷索引
  ├── CdnArchiveIndex.{h,m}         归档识别（名字 + 字节数 + sha256）
  ├── CdnImportPlan{,.generated}.{h,m}   导入计划与 634 条有序表（generated 为生成物）
  ├── CdnImportEngine.{h,m}         引擎：索引 → 预检 → 解压 → 收尾
  ├── assets/wanted-archives-ios.txt   634 个归档清单（可读形式）
  ├── tools/*.mjs                   6 个 Node 工具（注入、打包、计划校验、静态自检）
  └── README.md                     实现细节文档
tools/                 测试（node:test，无框架依赖）与测试运行器 run-tests.cjs
docs/                  使用说明 / 注入说明 / 验收清单
.github/workflows/     CI：macOS 编译 dylib、冒烟注入、发布
```

## 使用

### 1. 获取 `CdnImporter.dylib`

release（公开仓库，匿名可下载）：

```
https://github.com/NSDelta/wf-cdn-importer-iOS/releases/download/cdn-importer-latest/CdnImporter.dylib
```

其它途径：Actions artifact（需登录），或本地编译（编译命令见 CI 一节）。

### 2. 注入 IPA

若要修改游戏连接的服务器地址，先用 [IPApatcher](https://github.com/dennis96292/startpoint-cn-launcher/blob/main/tools/patch-ipa.mjs) 处理，该步骤必须在注入之前完成。然后：

```bash
node ios/importer/tools/inject-dylib.mjs \
  --ipa   /path/to/official.ipa \
  --dylib ./CdnImporter.dylib \
  --out   ./patched.ipa
```

注入前校验 16 条不变量（`ncmds` 只 +1、`sizeofcmds` 只 +72、所有 section 偏移与大小不变、命令区余量足够、条目不冲突、写入的 dylib 回读 sha256 一致等），任一失败则不写出文件。重复注入返回 `skipped: existing-load-command`。

dylib 在包内的位置由加载命令固定为 `@executable_path/Frameworks/CdnImporter.dylib`，IPA 条目名由该路径推导，与本地 dylib 文件名无关。

### 3. 侧载与导入

用 Sideloadly / AltStore 重签侧载 `patched.ipa`。免费 Apple ID 签名为 7 天有效期；重签为原地升级，已导入的资源不受影响。

1. 点击悬浮球 → 选文件夹 / 选文件。输入为追加式：可分多次添加，按路径去重，支持撤销上次与清空选择。
2. 预检（只读，不写盘），确认显示 `识别 634/634，缺 0`。
3. 开始导入，保持游戏在前台。可取消；取消后已导入部分保留，重跑时会先清空目标目录。
4. 终态为 `137820 个文件 / 10191161030 字节`，日志中出现写 `info.json` 与删除 4 个 partial。
5. 结束游戏进程后重新打开，客户端不再下载资源。

细节见 [`ios/importer/README.md`](ios/importer/README.md) 与 [`docs/使用说明.md`](docs/使用说明.md)。

## 数据契约

| 项目 | 值 |
| --- | --- |
| 目标版本 | CDN `1.4.54`（快照 `1.4.0` + 54 步 diff） |
| 归档数 | 634 = common 401 + medium 218 + ios 15（`archive-{common,medium,ios}-{full,diff}` 六个目录） |
| 压缩态合计 | 10,748,428,364 B（约 10.01 GiB） |
| 解开后 | 137,820 个文件 / 10,191,161,030 B（约 9.49 GiB） |
| 落盘位置 | `…/asset_download/<子目录>/download/<条目名>`，条目名为资源 hash，无扩展名 |
| 跳过的条目 | 以 `/` 结尾的目录项、`*.empty`、`*.hash` |
| 覆盖语义 | 同名条目后写覆盖先写，因此必须按计划顺序解压（快照在前，diff 按 `original_version → version` 串链在后），顺序固定在 `CdnImportPlan.generated.m` |
| 收尾文件 | `info.json`：`version 1.4.54`、`assetRecoveryInfo []`、`totalSize 10191161030`、`assetSizeKind fulfill` |
| 平台层 | Android 的 `archive-android-*` 不参与 |

校验强度：默认校验归档名、归档字节数与逐条目 CRC32；打开深度校验后额外校验整包 sha256（需二次读取，耗时约翻倍）。

## 测试与自检

```bash
node tools/run-tests.cjs                 # 4 个测试文件：ZIP 解析护栏 / 计划一致性 / 静态自检 / 注入器
node tools/run-tests.cjs --filter inject # 只运行文件名含 inject 的测试
node tools/run-tests.cjs --list          # 列出将运行的文件

node ios/importer/tools/lint-objc.mjs --stats   # ObjC 静态自检
```

`lint-objc.mjs` 覆盖的是本机（Windows）无法编译 ObjC、只能等 CI 才能发现的错误：跨类访问私有 ivar、向 `UIViewController` 发送其未声明的 selector、头文件 import 闭包缺项、长循环缺少 `@autoreleasepool`、读取可用空间前未定位已存在目录、悬浮球窗口等级高于其它插件等。每条规则在测试中有对应用例。

对照本地 CDN 复核计划与终态，不需要设备：

```bash
node ios/importer/tools/verify-plan.mjs --cdn <你的 cdn 目录> --quiet
# 连 sha256 一起校验（读完 10.7 GB，较慢）：把 --quiet 换成 --sha256
```

## CI

`.github/workflows/ios-importer.yml` 在 push 到 `ios/importer/**`、`tools/**` 或手动派发时运行：

* **test**：静态自检 + 单元测试；
* **build**（macOS runner）：用以下命令编译 `CdnImporter.dylib`。

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

构建后依次执行：ad-hoc 签名 → 合成迷你 IPA 端到端运行注入器并断言 → 输出三条零凭据诊断通道（运行页注解 / `ci-diag/<run_id>` 分支 / artifact）→ dylib 发布到滚动 release → 兜底推送 `cdn-artifacts/<run_id>` 分支（raw 直链匿名可取）。

### 关于 `baseUrl`

dylib 内嵌的 `baseUrl` 只写入 `info.json`，客户端仅在资源恢复（Recovery）时读取它。导入器写入 `assetRecoveryInfo: []`，服务端 `files_list` 为空表，Recovery 不会触发，因此占位地址不影响功能。需要真实值有两个途径：手动派发 workflow 时填写 `patch_base` 输入，或运行期设置 `NSUserDefaults` 的 `CdnImporterPatchBase`。

修改游戏连接的服务器地址是另一件事，不在本仓库范围内（由主项目/交付包中的改址脚本完成），且必须在注入之前应用。

## 文档索引

| 文件 | 内容 |
| --- | --- |
| [`ios/importer/README.md`](ios/importer/README.md) | 实现细节：数据契约、客户端消费方式、编译与部署、设备步骤、失败语义、日志排查、已知限制 |
| [`docs/使用说明.md`](docs/使用说明.md) | 使用者视角：资源来源、五种送入设备的途径、设备上导入流程、终态核对、常见问题 |
| [`docs/注入说明.md`](docs/注入说明.md) | dylib 说明、编译命令、三步注入、换服务器地址的三种情况、回退方式 |
| [`docs/验收清单.md`](docs/验收清单.md) | 真机逐项验收清单（A 包与环境 → J 记录表），含通过 / 有条件通过 / 不通过判定口径 |
| [`ios/importer/assets/wanted-archives-ios.txt`](ios/importer/assets/wanted-archives-ios.txt) | 634 个归档清单（设备侧读取的是编译进 dylib 的表） |

## 许可

GPLv3，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。

仅用于自建服务器、离线备份与逆向研究；请自备正版客户端与自己的 CDN 数据，不要分发游戏资源。
