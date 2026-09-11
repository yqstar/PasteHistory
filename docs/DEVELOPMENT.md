# 开发与数据格式

[返回 README](../README.md)

使用 Swift / AppKit 编写，无第三方依赖，最低支持 macOS 13。

## 构建与验证

安装 Xcode Command Line Tools 后，在仓库根目录运行：

| 命令 | 用途 |
| --- | --- |
| `bash build.sh` | 构建 Apple Silicon / Intel 通用应用，输出至 `build/PasteHistory.app` |
| `bash test.sh` | 验证数据保存、备份恢复、搜索和更新检查逻辑 |
| `bash test-ui.sh` | 在图形会话中验证片段编辑、草稿保护、剪贴板恢复与快捷键录制 |
| `bash screenshots.sh` | 使用真实 AppKit 界面和临时示例数据生成文档截图 |
| `bash make-dmg.sh` | 打包为 `build/PasteHistory.dmg` |

界面测试截图位于 `build/snippet-ui-screenshots/`。文档截图位于 `build/readme-screenshots/`，其中 `qa/` 包含小窗口与空状态；检查后将主目录 PNG 复制到 `docs/screenshots/`。截图工具不读写日常历史，不监听系统剪贴板，也不注册全局快捷键。

## 项目结构

```text
Sources/
├── App/       # 应用入口、菜单栏和模块组装
├── Core/      # 数据模型、搜索、持久化和更新检查
├── macOS/     # 剪贴板、自动粘贴、全局快捷键和开机启动
└── UI/        # 公共组件、选择器、片段编辑器、设置与更新窗口
Tests/
├── Logic/     # 数据、搜索、快捷键注册和更新检查测试
└── SnippetUI/ # 使用临时数据的 AppKit 界面测试
Tools/
├── swift-common.sh # 构建、测试和截图共用的编译配置
├── Screenshots/    # 文档截图工具
└── release-notes.py
Resources/          # 应用图标
docs/screenshots/   # README 使用的截图
build/              # 本机构建产物与测试截图，不提交到 Git
```

根目录保留 `build.sh`、`test.sh`、`test-ui.sh`、`screenshots.sh` 和 `make-dmg.sh` 作为命令入口。应用构建、界面测试和截图工具会递归收集 `Sources` 中的 Swift 文件，并分别使用自己的 `main.swift`；逻辑测试只编译核心文件与快捷键模块。

界面颜色和图标定义集中在 `Sources/UI/Components.swift`，系统快捷键注册和配置保存在 `Sources/macOS/HotKey.swift`。目前仍是单个 macOS 编译模块，片段数据保留原有 Carbon 快捷键格式。

## 本地数据

```text
~/Library/Application Support/PasteHistory/
├── history.json      # 文本、文件路径和图片元数据
├── snippets.json     # 已保存的片段
├── history.json.bak  # 上一版历史数据
├── snippets.json.bak # 上一版片段数据
└── images/           # 剪贴板图片（PNG）
```

主文件损坏或缺失时会尝试恢复备份，损坏文件会改名保留并显示提示。片段可以在“设置 → 数据管理 → 片段备份”中导入或导出 JSON；导入可按 UUID 合并，也可替换全部。

## 代码片段格式

`snippets.json` 是一个 JSON 数组：

```json
[
  {
    "id": "11111111-2222-3333-4444-555555555555",
    "title": "邮箱签名",
    "content": "Best,\n张三",
    "hotKey": {
      "keyCode": 18,
      "carbonModifiers": 2304,
      "display": "⌥⌘1"
    }
  }
]
```

- `id` 为 UUID。
- `title` 和 `content` 分别是片段标题与实际粘贴内容。
- `hotKey` 可省略；设置后可以用独立全局快捷键直接粘贴该片段。
- 直接编辑 JSON 后需要重启应用；日常使用建议通过设置中的导入、导出功能管理。

## 自动发布

项目使用 [GitHub Actions](../.github/workflows/release.yml) 自动构建 Release。推送符合 `vMAJOR.MINOR.PATCH` 格式的标签后，工作流会：

1. 运行数据与搜索逻辑测试。
2. 构建 Apple Silicon 与 Intel 双架构应用。
3. 校验应用签名与 DMG。
4. 生成带版本号的 Universal DMG 和 SHA-256 文件。
5. 从 `CHANGELOG.md` 提取对应版本的中文说明，并附加 GitHub 自动生成的变更链接后创建 Release。

发布前，将 `Info.plist` 中的版本号更新为目标版本，并在 `CHANGELOG.md` 最上方添加该版本的记录与发布日期。工作流会校验标签和应用版本一致、对应说明非空。发布示例：

```bash
# 将 x.y.z 替换为准备发布的版本号
git tag -a vx.y.z -m "PasteHistory vx.y.z"
git push origin vx.y.z
```

## 实现说明

- 应用仅监听通用剪贴板 `NSPasteboard.general`，根据活跃程度以 0.3–2 秒间隔轮询。
- 全局快捷键使用 Carbon `RegisterEventHotKey` 注册。
- 当前构建使用 ad-hoc 签名；正式分发如需 Apple 公证，应在发布工作流中配置 Developer ID 签名、公证与 stapling。
