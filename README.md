# wf-cdn-importer-iOS

《World Flipper》（弹射世界）**国服 iOS 1.8.4** 的**非越狱资源导入器**。

它把一个动态库（`CdnImporter.dylib`）注入到官方 IPA 里，侧载后跑在游戏自己的进程内：游戏沙盒里出现一个悬浮球，你把官方 CDN 的归档压缩包（zip / tar 分卷 / 整包）交给它，它会**按快照 + diff 链的正确顺序**把 634 个归档解压进

```
<容器>/Library/Application Support/com.leiting.wf/Local Store/asset/asset_download/<子目录>/download/
```

并写一份 `info.json`、删掉 4 个 `partial_downloaded*` —— 客户端启动时判定「资源已下载且完整」，于是**不再联网下载那 9.5 GB 资源**。

* **非越狱**：不加 MobileSubstrate、不 hook 任何方法、不做方法交换，只是一个 `__attribute__((constructor))` + 悬浮球 + 文件写入。
* **不碰客户端的下载链路**：不改网络、不拦下载、不模拟服务器；它只是提前把文件放到位。
* **可离线**：全部解压与校验在设备本地完成，导入过程不需要联网（只有游戏本身连你的服务器时需要局域网）。

> 本仓库**不含**游戏本体、IPA 与任何 CDN 数据。需要你自备正版 IPA 与自己的 CDN 归档。

---

## 目录结构

```
.
├── ios/importer/                      # 导入器本体（Objective-C，21 个文件）
│   ├── CdnImporterEntry.m             #   唯一入口：constructor + 启动通知 + 定时兜底
│   ├── CdnImporterConfig.{h,m}        #   路径 / 日志 / 目标目录探测 / 资源完整度判定
│   ├── CdnImporterOverlay.{h,m}       #   悬浮球窗口（与别的悬浮插件同层共存）
│   ├── CdnImporterPanelViewController.{h,m}  # 面板：选输入 / 预检 / 导入 / 日志
│   ├── CdnArchiveSource.{h,m}         #   File / Memory / Concat / Subrange 读取源
│   ├── CdnZipArchive.{h,m}            #   ZIP 中央目录解析 + 流式解压（逐条目 CRC32）
│   ├── CdnTarIndex.{h,m}              #   tar / tar 分卷索引
│   ├── CdnArchiveIndex.{h,m}          #   归档识别（按名字 + 字节数 + sha256）
│   ├── CdnImportPlan.{h,m}            #   计划：有序归档表 + info.json 契约
│   ├── CdnImportPlan.generated.{h,m}  #   634 个归档的有序表（生成物，勿手改）
│   ├── CdnImportEngine.{h,m}          #   四阶段引擎：索引 → 预检 → 解压 → 收尾
│   ├── assets/wanted-archives-ios.txt #   634 个归档清单（人读用）
│   ├── tools/                         #   纯 Node 工具（无 npm 依赖）
│   │   ├── inject-dylib.mjs           #     注入 dylib 到 IPA（Mach-O 加一条 LC_LOAD_DYLIB）
│   │   ├── make-mini-ipa.mjs          #     合成迷你 IPA（测试/冒烟用）
│   │   ├── verify-plan.mjs            #     对着本地 CDN 复核计划与终态
│   │   ├── plan-lib.mjs               #     计划构建库（verify-plan 用）
│   │   ├── build-tar.mjs              #     把 634 归档打成 tar / 分卷 tar
│   │   ├── lint-objc.mjs              #     ObjC 静态自检（编译期错误的提前拦截）
│   │   └── lib/{zip-ipa,ios-macho}.mjs#     ZIP / Mach-O 最小实现（被上面两个 import）
│   └── README.md                      # 详细文档（数据契约 / 部署 / 设备步骤 / 排查）
├── tools/
│   ├── ios_importer_{plan,zip,lint,inject}.test.cjs  # 测试（node:test，无框架依赖）
│   └── run-tests.cjs                  # 测试运行器
├── docs/                              # 使用说明 / 注入说明 / 验收清单
└── .github/workflows/ios-importer.yml # CI：macos 上编译 dylib + 冒烟注入 + 发布
```

---

## 快速开始

### 1. 拿 `CdnImporter.dylib`

三种取法（任选）：CI 的滚动 release（公开仓库匿名可下）

```
https://github.com/NSDelta/wf-cdn-importer-iOS/releases/download/cdn-importer-latest/CdnImporter.dylib
```

或 Actions 的 artifact（**需要登录**），或自己编（见下）。

### 2. 注入到 IPA

```bash
node ios/importer/tools/inject-dylib.mjs \
  --ipa   /path/to/official.ipa \
  --dylib ./CdnImporter.dylib \
  --out   ./patched.ipa
```

注入器会断言 16 条不变量（`ncmds` 只 +1、`sizeofcmds` 只 +72、所有 section 偏移与大小不变、命令区余量够、条目不冲突、dylib 回读 sha256 一致……），任何一条不过就不写输出文件。幂等：已注入过的 IPA 再跑会报 `skipped: existing-load-command`。

> 安装名固定为 `@executable_path/Frameworks/CdnImporter.dylib`，IPA 里的条目名由它推导 —— 你可以随意改本地 dylib 的文件名，包内路径不会跑偏。

### 3. 侧载并导入

用 Sideloadly / AltStore 等重签侧载 `patched.ipa`（免费 Apple ID 是 7 天有效期，**重签是原地升级，已导入的资源不会丢**）。进游戏后：

1. 悬浮球 → **选文件夹** / **选文件**（追加式：可以分多次把归档或 tar 分卷一项项加进来，按路径去重，可「撤销上次」「清空选择」）；
2. 点 **预检**（只读，不写盘）——确认面板显示 `识别 634/634，缺 0`；
3. 点 **开始导入**，保持游戏在前台（可取消；取消后已导入的部分保留，重跑会先清空再重来）；
4. 终态应为 `137820 个文件 / 10191161030 字节`，日志里出现写 `info.json`、删 4 个 partial；
5. 杀掉游戏重开 —— 客户端不再下载资源。

细节见 [`ios/importer/README.md`](ios/importer/README.md) 与 [`docs/使用说明.md`](docs/使用说明.md)。

---

## 数据契约（必须与客户端一致）

| 项目 | 值 |
| --- | --- |
| 目标版本 | CDN `1.4.54`（快照 `1.4.0` + 54 步 diff） |
| 归档数 | **634** = common 401 + medium 218 + ios 15（`archive-{common,medium,ios}-{full,diff}` 六个目录） |
| 压缩态合计 | 10,748,428,364 B（≈ 10.01 GiB） |
| 解开后 | **137,820 个文件 / 10,191,161,030 B**（≈ 9.49 GiB） |
| 落盘路径 | `…/asset_download/<子目录>/download/<条目名>`（条目名 = 资源 hash，无扩展名） |
| 跳过条目 | 以 `/` 结尾的目录项、`*.empty`、`*.hash` |
| 覆盖语义 | **同名后写覆盖先写** —— 所以必须按计划顺序解压（快照在前，diff 按 `original_version → version` 串链在后），顺序由 `CdnImportPlan.generated.m` 固定 |
| 收尾文件 | `info.json`：`version 1.4.54`、`assetRecoveryInfo []`、`totalSize 10191161030`、`assetSizeKind fulfill` |
| 平台层 | Android 的 `archive-android-*` **不参与**（iOS 只用 common + medium + ios） |

校验强度：按名字识别归档 + 校验每个归档的字节数 + **逐条目 CRC32**（默认，零额外 IO）；面板打开「深度校验」再加一道整包 sha256（要读第二遍，时间约翻倍）。

---

## 测试与自检

```bash
node tools/run-tests.cjs                 # 4 个测试文件（ZIP 解析护栏 / 计划一致性 / 静态自检 / 注入器）
node tools/run-tests.cjs --filter inject # 只跑文件名含 inject 的
node tools/run-tests.cjs --list          # 列出会跑哪些文件

node ios/importer/tools/lint-objc.mjs --stats   # ObjC 静态自检（21 个文件 / 55 个类与方法 / 25 个声明）
```

`lint-objc.mjs` 拦的是「本机（Windows）编不了 ObjC、只能等 CI 才发现」的低级错误：私有 ivar 跨类访问、`UIViewController` 上不存在的 selector、头文件 import 闭包缺失、长循环里漏 `@autoreleasepool`、读可用空间前没找已存在目录、悬浮球窗口等级压过别的插件等。每条规则都有对应的测试用例（见 `tools/ios_importer_lint.test.cjs`）。

对着本地 CDN 复核计划与终态（不需要设备）：

```bash
node ios/importer/tools/verify-plan.mjs --cdn <你的 cdn 目录> --quiet
# 全量读一遍比 sha256（10.7 GB，慢）：把 --quiet 换成 --sha256
```

---

## CI

`.github/workflows/ios-importer.yml`（push 到 `ios/importer/**` 或 `tools/**` 或手动派发）：

* **test**：`lint-objc.mjs --stats` + `tools/run-tests.cjs`；
* **build**（macos runner，本机是 Windows 编不了 ObjC）：

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

（`CDN_IMPORT_PATCH_BASE` 只是写进 `info.json.baseUrl` 的占位地址，见下。）

构建完还会：ad-hoc 签名 → 合成迷你 IPA 端到端跑一遍注入器并断言 → 三条零凭据诊断通道（运行页注解 / `ci-diag/<run_id>` 分支 / artifact）→ 把 dylib 推到滚动 release → 兜底再推一条 `cdn-artifacts/<run_id>` 分支（raw 直链匿名可取，适合没有 token 的场景）。

### 关于 `baseUrl`

dylib 里内嵌的 `baseUrl` **只进 `info.json`**，而客户端只在「资源恢复（Recovery）」时才会用它；导入器写的是 `assetRecoveryInfo: []`，服务器侧的 `files_list` 也是空表 ⇒ Recovery 永不触发，占位地址不影响任何功能。要真实值有两条路：

* 手动派发 workflow 时填 `patch_base` 输入；
* 运行期设 `NSUserDefaults` 的 `CdnImporterPatchBase`。

改**游戏连接的游戏服务器地址**是另一件事（不属于本仓库，由主项目/交付包里的改址脚本做），必须在注入之前应用。

---

## 文档索引

| 文件 | 内容 |
| --- | --- |
| [`ios/importer/README.md`](ios/importer/README.md) | 实现细节：数据契约、客户端怎么消费、编译与部署、设备上 5 步、失败语义、日志排查、已知限制、文件清单 |
| [`docs/使用说明.md`](docs/使用说明.md) | 使用者视角：资源从哪来、五种送进手机的途径、设备上怎么导入、终态核对、常见问题 |
| [`docs/注入说明.md`](docs/注入说明.md) | dylib 是什么、CI 里的编译命令、三步注入、换服务器地址的三种情况、回退办法 |
| [`docs/验收清单.md`](docs/验收清单.md) | 真机验收逐项清单（A 包与环境 → J 记录表），带通过/有条件通过/不通过的判定口径 |
| [`ios/importer/assets/wanted-archives-ios.txt`](ios/importer/assets/wanted-archives-ios.txt) | 634 个归档的人读清单（设备侧读的是编译进 dylib 的 C 表） |

## 许可

GPLv3（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）。
仅用于自建服务器、离线备份与逆向研究；请自备正版客户端与自己的 CDN 数据，不要分发游戏资源。
