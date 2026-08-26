# 黑羽阅读 📖

一个用 Flutter 编写的电子书阅读应用，支持 Android 与 iOS。

## 功能特性

- **本地阅读**：支持 TXT / EPUB 格式，自动识别 UTF-8 / GBK / UTF-16 编码（内置 WHATWG 标准 GBK 码表，完美支持中文网络小说常见编码）
- **智能分章**：TXT 自动识别「第X章/回/卷/节」标题（含中文数字），无章节标记时按定长智能切块
- **WiFi 传书**：手机启动本地 HTTP 服务，电脑浏览器扫码或输入地址，拖拽批量上传，自动导入书架
- **书源订阅**：通过订阅 URL 导入第三方书源（兼容「阅读 legado」书源 JSON 格式常用子集），支持剪贴板直接粘贴 JSON
- **多源搜索**：并发搜索所有启用的书源，实时显示各书源状态，支持翻页加载
- **在线阅读**：搜索结果一键加入书架，目录抓取、正文抓取、章节缓存、下一章预取
- **阅读器**：字号 / 行距 / 段距调节，5 种阅读主题（素白 / 翠绿 / 羊皮 / 暗夜 / 墨黑），目录跳转，章节进度自动记忆，全屏沉浸阅读

## 构建运行

要求 Flutter ≥ 3.27（Dart ≥ 3.5）。

```bash
flutter pub get

# 连接设备直接运行
flutter run

# 构建 Android APK
flutter build apk --release

# 构建 iOS（需要 macOS + Xcode）
flutter build ios --release
```

- Android applicationId：`com.heiyu.heiyu_reader`
- iOS Bundle：`com.heiyu.heiyuReader`（可在 Xcode 中修改签名配置）
- 应用显示名已配置为「黑羽阅读」（AndroidManifest.xml / Info.plist）
- 更换应用图标：替换 `android/app/src/main/res/mipmap-*/ic_launcher.png` 与 `ios/Runner/Assets.xcassets/AppIcon.appiconset`，或使用 `flutter_launcher_icons`

## 使用说明

### WiFi 传书
1. 确保电脑与手机连接同一 WiFi
2. 「传输」页点击「启动传输」
3. 电脑浏览器打开显示的地址（或扫描二维码）
4. 拖拽 .txt / .epub 文件上传，自动进入书架

### 书源订阅
1. 「书源」页点击右上角 ＋
2. 输入书源订阅地址（支持返回书源 JSON 数组的 URL），或点击「从剪贴板」导入
3. 导入后可单独启用 / 停用 / 删除

书源规则兼容「阅读」app 格式的常用子集：

| 字段 | 说明 |
|---|---|
| `searchUrl` | 搜索地址，`{{key}}` 为关键词、`{{page}}` 为页码；支持 `,{"method":"POST","body":"..."}` 选项后缀 |
| `ruleSearch.bookList/name/author/intro/coverUrl/bookUrl/lastChapter` | 搜索结果规则 |
| `ruleToc.chapterList/chapterName/chapterUrl/nextTocUrl` | 目录规则（支持目录翻页） |
| `ruleContent.content/replaceRegex` | 正文规则（`replaceRegex` 格式 `正则##替换`） |

选择器语法：

- `class.名称` / `id.名称` / `tag.名称` / `children`
- `@` 链式：`class.bookbox@tag.a@text`
- 索引：`class.list.0`、`tag.a@-1`（负数从末尾）
- 终结符：`text` / `textNodes` / `ownText` / `html`
- 属性：`href` / `src` / 任意属性名
- 回退：`规则A||规则B`（A 无结果时用 B）

> 注：包含 JS 求值（`<js></js>`）、XPath、CSS 选择器等高级特性的书源规则不在支持范围内，建议使用简单规则书源。

### 搜索与阅读
「搜索」页输入关键词 → 查看各书源结果 → 点进详情页加入书架 → 选章阅读。网络书籍章节自动缓存，支持离线重读已缓存章节。

## 技术说明

```
lib/
├── main.dart / theme.dart        # 入口与暗夜羽金主题
├── models/models.dart            # 数据模型
├── db/app_database.dart          # sqflite（书架/书源/章节缓存）
├── utils/
│   ├── gbk_table.dart            # WHATWG gb18030 标准码表（自动生成）
│   ├── text_encoding.dart        # 编码检测与解码
│   └── html_text.dart            # HTML → 阅读文本
├── parsers/
│   ├── txt_parser.dart           # TXT 智能分章
│   └── epub_parser.dart          # EPUB 解析（OPF/spine/NCX/封面）
├── engine/
│   ├── selector.dart             # 书源规则选择器引擎
│   └── source_engine.dart        # 搜索/目录/正文抓取
├── services/
│   ├── wifi_server.dart          # WiFi 传书 HTTP 服务 + 上传页面
│   └── importer.dart             # 书籍导入
├── pages/                        # 书架/搜索/书源/传输/阅读器/详情
└── widgets/                      # 封面/羽毛图标/目录抽屉
```

测试：`test/` 下包含编码检测、分章、EPUB 解析、选择器、书源全流程（本地 HTTP 模拟站点）共 20 项单元测试，`flutter test` 运行。

## 注意事项

- 书源抓取依赖目标网站页面结构，站点改版可能导致规则失效
- iOS 首次联网抓取书源时如系统询问「本地网络」权限请允许
- 请尊重内容版权，仅将本应用用于阅读合法获取的内容

## 发布打包

**Android**（已配置好签名，密钥在 `android/app/upload-keystore.jks`，密码在 `android/key.properties`，**务必备份这两个文件**，丢失后无法覆盖更新）：

```bash
flutter build apk --release          # 通用 APK
flutter build appbundle --release    # 上架 Play 用 AAB
```

**iOS**（需要 Apple 开发者账号）：Xcode 打开 `ios/Runner.xcworkspace`，Runner target → Signing & Capabilities 选你的 Team，然后：

```bash
flutter build ipa --release
```
