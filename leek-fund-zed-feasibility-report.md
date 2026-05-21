# leek-fund（韭菜盒子）改造为 Zed 插件可行性调研报告

> **调研日期**: 2026-05-21
> **调研范围**: leek-fund VS Code 插件 → Zed 编辑器插件改造可行性
> **研究方法**: 10 维度并行深度调研 + 交叉验证 + 洞察提取
> **信息来源**: GitHub 源码、Zed 官方文档、社区 RFC、开发者讨论等 200+ 独立搜索

---

## 执行摘要

**核心结论：在当前（2026-05）Zed 扩展 API（v0.7.0）的技术约束下，leek-fund 不适合改造为 Zed 插件。**

leek-fund 是一款功能丰富的 VS Code 金融数据插件（3.7k stars，27,896 行 TypeScript），其核心功能——侧边栏基金/股票列表、底部状态栏实时行情、走势图/WebView 弹窗——全部重度依赖 VS Code 的 UI API（TreeView、StatusBar、WebView）。而 Zed 的扩展系统目前完全不支持自定义 UI 组件，且官方已明确表示不会兼容 VS Code Extension API。

**关键数据一览：**

| 维度 | 评估结果 |
|------|---------|
| 功能覆盖度 | 80-90% 核心功能在 Zed 中**无法实现** |
| 技术栈兼容性 | TypeScript/Node.js → Rust/WASM，**完全不兼容** |
| 代码可复用率 | 约 70% 数据层逻辑可借鉴，UI 层需 100% 重写 |
| 预计工作量 | 完整移植需 6-12 个月（2-3 名 Rust 开发者） |
| 分发生态 | Zed ~1000 扩展，无金融类插件先例 |
| 未来可行性 | RFC #53403 (Visual Extension API) 处于 Draft 状态，最早 2026 Q3 评估 |

---

## 一、leek-fund 项目分析

### 1.1 项目概况

leek-fund（韭菜盒子）是 VS Code 平台上最受欢迎的金融数据插件之一：

- **GitHub**: LeekHub/leek-fund，3,717 stars，553 forks，30 位贡献者
- **版本**: v3.24.0（2026-04-23），78 次正式发布
- **语言**: TypeScript（93.8%）+ HTML/Less/CSS
- **代码规模**: 68 个 TypeScript 文件，约 27,896 行代码
- **定位**: 在 VS Code 中实时查看股票、基金、期货行情数据

### 1.2 核心功能

| 功能模块 | 实现方式 | 用户价值 |
|---------|---------|---------|
| 基金/股票/期货侧边栏列表 | TreeView API | 高频使用，核心功能 |
| 底部状态栏实时行情 | StatusBarItem API | 高频使用，盯盘必备 |
| 走势图/K 线图弹窗 | WebView API | 中频使用，分析工具 |
| 基金排行榜 & 资金流向 | WebView API | 中频使用，辅助决策 |
| 盈亏计算 & 持仓管理 | TreeView + Configuration | 中频使用，投资管理 |
| 快讯 & 新闻推送 | OutputChannel API | 低频使用，信息补充 |
| AI Agent 助手 | WebView API | v3.20.5+ 新增 |

### 1.3 技术架构

```
leek-fund/
├── src/explorer/          # TreeView 提供者（5 个 Provider）
│   ├── stockProvider.ts   # 股票 TreeView
│   ├── fundProvider.ts    # 基金 TreeView
│   ├── newsProvider.ts    # 新闻 TreeView
│   └── *Service.ts        # 数据服务层
├── src/statusbar/         # 状态栏实现
├── src/webview/           # WebView 面板（20+ 个）
├── src/service/           # 数据源封装（新浪/腾讯/东方财富/雪球）
├── src/globalState.ts     # 持久化存储
└── extension.ts           # 扩展入口（304 行）
```

**数据源**: 新浪 `hq.sinajs.cn`、腾讯 `qt.gtimg.cn`、东方财富、天天基金、雪球 API、币安 API、百度外汇 API 等 12+ 个数据源。

### 1.4 VS Code API 依赖分析

leek-fund 对 VS Code Extension API 有**深度且全面的依赖**，几乎所有源文件都直接导入 `vscode` 模块：

| API 类别 | 依赖程度 | Zed 对应 | 替代难度 |
|---------|---------|---------|---------|
| TreeDataProvider / TreeView | 🔴 核心 | ❌ 不存在 | 极高 |
| StatusBarItem | 🔴 核心 | ❌ 不存在 | 极高 |
| WebviewPanel / Webview | 🔴 核心 | ❌ 不存在* | 极高 |
| Commands (registerCommand) | 🔴 核心 | 🔶 Slash Command | 高 |
| Configuration | 🔴 核心 | 🔶 部分支持 | 高 |
| OutputChannel | 🟡 中等 | ❌ 不存在 | 高 |
| globalState / workspaceState | 🔴 核心 | ✅ KeyValueStore | 低 |
| window.show* 对话框 | 🟡 中等 | ❌ 不存在 | 中 |
| HTTP Client (axios) | 🟡 中等 | ✅ http_client::fetch | 低 |

*Zed 已明确排除 WebView 支持，选择 GPUI 原生渲染路线。

---

## 二、Zed 插件系统现状

### 2.1 Zed Extension API 概览

Zed 采用 **Rust → WASM** 架构，插件通过 `zed_extension_api` crate 开发，编译为 WebAssembly 后由 Zed 内嵌的 Wasmtime 运行时加载。

**核心参数：**

| 参数 | 值 |
|------|-----|
| API 版本 | zed_extension_api 0.7.0（2026-04） |
| Zed 主版本 | 1.0（2026-04-30 发布） |
| 官方开发语言 | Rust（唯一官方支持） |
| 运行时 | Wasmtime（WASM 沙箱） |
| 接口定义 | WIT（WebAssembly Interface Types） |
| 编译目标 | wasm32-wasip2 |

### 2.2 Zed 插件能做什么

当前 Zed 扩展 API 支持 6 大类功能：

1. **语言服务器 (LSP)** — 语言支持、语法高亮、代码补全
2. **调试器 (DAP)** — 调试适配器协议支持
3. **主题** — 颜色主题、图标主题
4. **代码片段** — 代码模板
5. **MCP 服务器** — Model Context Protocol 工具集成
6. **Slash 命令** — AI Agent 对话中的斜杠命令

### 2.3 Zed 插件不能做什么（关键限制）

以下限制直接阻断 leek-fund 的核心功能：

| 限制项 | 对 leek-fund 的影响 |
|--------|-------------------|
| ❌ 无 TreeView / Sidebar Panel API | 无法展示基金/股票列表 |
| ❌ 无 StatusBar API | 无法显示底部实时行情 |
| ❌ 无 WebView / 自定义 UI API | 无法显示走势图、K 线图、设置面板 |
| ❌ 无 OutputChannel API | 无法输出快讯信息 |
| ❌ 无对话框 API (InputBox/QuickPick) | 无法支持 GUI 交互操作 |
| ❌ 无 JS/TS 运行时 | 需要完全重写为 Rust |

Zed 官方文档明确说明：

> "There's no support for modifying the UI to create new panels, or making arbitrary HTTP requests, or touching the file system how you want." — Zed 官方博客, 2024-10-21

### 2.4 未来展望：RFC #53403

2026 年 4 月，社区提交了 **Visual Extension API RFC** (Discussion #53403)，计划分 4 阶段开放 UI 能力：

| 阶段 | 内容 | 对 leek-fund 的意义 |
|------|------|-------------------|
| Phase 1 | Status Bar API | 底部行情显示 🟢 |
| Phase 2 | Panel API (Sidebar) | 侧边栏列表展示 🟢 |
| Phase 3 | Interactive Components | 按钮、表单等交互 🟡 |
| Phase 4 | Advanced Components | 图表、复杂组件 🟡 |

**重要警告**：
- RFC 目前处于 **Draft 状态**，无官方承诺实现时间
- Zed 团队 **明确排除 WebView** 支持，走势图需用 GPUI 原生重写
- 预估完整实现需 4-6 个月（如社区通过）

---

## 三、可行性评估

### 3.1 功能映射评估

| leek-fund 功能 | VS Code API | Zed 当前 | Zed RFC 后 | 可行性 |
|---------------|------------|---------|-----------|--------|
| 侧边栏基金/股票列表 | TreeView | ❌ | ✅ Panel API | 需等待 |
| 底部状态栏行情 | StatusBarItem | ❌ | ✅ Status Bar API | 需等待 |
| 走势图/K线图 | WebView | ❌ | ❌** | 不可行 |
| 快讯输出面板 | OutputChannel | ❌ | ❓ 未知 | 不确定 |
| GUI 配置面板 | WebView + Forms | ❌ | 🔶 部分 | 需简化 |
| 数据自动刷新 | setInterval | ✅ Rust timer | ✅ Rust timer | 可行 |
| 数据持久化 | globalState | ✅ KeyValueStore | ✅ KeyValueStore | 可行 |
| HTTP 数据获取 | axios/fetch | ✅ http_client | ✅ http_client | 可行 |

*Zed 明确排除 WebView，走势图需 GPUI 原生实现，工作量巨大。

### 3.2 技术栈迁移评估

| 维度 | 现状 | 迁移要求 | 难度 |
|------|------|---------|------|
| 编程语言 | TypeScript | Rust | 高（团队需学习 Rust） |
| 编译目标 | Node.js 模块 | WASM (wasm32-wasip2) | 高 |
| UI 框架 | HTML/CSS/JS (WebView) | GPUI (Rust 原生) | 极高 |
| HTTP 客户端 | axios | zed_extension_api::http_client | 低 |
| 数据解析 | JS/TS 函数 | Rust 函数 | 中 |
| 状态管理 | VS Code Memento | KeyValueStore | 低 |

### 3.3 工作量估算

| 方案 | 工作量 | 团队配置 | 时间 |
|------|--------|---------|------|
| 完整移植（全部功能） | 12-24 人月 | 2-3 名 Rust 开发者 | 6-12 个月 |
| 简化版（仅 Slash Command 文本输出） | 2-4 人周 | 1 名 Rust 开发者 | 2-4 周 |
| MCP Server 封装 | 1-2 人周 | 1 名开发者（任何语言） | 1-2 周 |
| 等待 RFC 后移植 | 不可估算 | 依赖 RFC 进展 | 最早 2026 Q3 |

---

## 四、关键障碍与风险

### 🔴 阻断性障碍

1. **UI API 完全缺失**
   - TreeView、StatusBar、WebView 是 leek-fund 的核心 UI 支柱
   - Zed 当前不支持，且部分 API（WebView）永远不会支持
   - 影响面：80-90% 的用户可见功能

2. **技术栈完全不兼容**
   - TypeScript → Rust 不是迁移，是重写
   - HTML/CSS WebView → GPUI 是两套完全不同的 UI 范式
   - 27,896 行代码几乎无一可复用

3. **图表功能永久不可行**
   - 走势图、K 线图依赖 WebView + HTML/JS 图表库
   - Zed 明确排除 WebView，选择 GPUI 原生渲染
   - 即使 RFC 全部实现，图表功能也需要从零用 GPUI 重写

### 🟡 高风险项

4. **RFC 时间不确定**
   - Visual Extension API RFC 处于 Draft 状态
   - 无官方承诺，可能延期或被拒绝
   - 即使通过，实现周期 4-6 个月

5. **目标用户基数小**
   - Zed 用户量远小于 VS Code（扩展数 1000 vs 50000+）
   - 金融数据插件是垂直小众需求
   - ROI 不确定

### 🟢 低风险项

6. **数据层可复用**
   - HTTP 请求逻辑和数据解析逻辑与 VS Code 无关
   - 12+ 个数据源接口可以直接借鉴
   - 可复用约 70% 的业务逻辑思路

---

## 五、替代方案

### 方案 A: 完整移植到 Zed 插件（❌ 不推荐）

- **工作量**: 6-12 个月，2-3 名 Rust 开发者
- **产出**: 功能大幅缩减的版本（无走势图，无复杂 UI）
- **ROI**: 极低
- **风险**: 极高

### 方案 B: 简化版 Zed 插件 — Slash Command（🟡 有条件推荐）

- **工作量**: 2-4 周
- **产出**: 通过 `/fund` `/stock` 等命令在 AI Agent Panel 中以 Markdown 文本输出行情
- **优势**: 可复用数据层逻辑，符合 Zed AI-first 方向
- **劣势**: 体验与 VS Code 版本差距巨大
- **适用场景**: Zed 用户的轻度查询需求

### 方案 C: MCP Server 封装（🟢 推荐短期方案）

- **工作量**: 1-2 周
- **产出**: 将 leek-fund 数据层封装为 MCP Server，供 Zed AI Agent 调用
- **优势**: 
  - 投入最小，可复用全部数据逻辑
  - 可在任何支持 MCP 的编辑器中使用
  - 符合 Zed 的 AI Agent 战略方向
- **劣势**: 纯文本交互，无可视化

### 方案 D: 保持现状 + 持续跟踪（🟢 推荐长期策略）

- **策略**: 维持 VS Code 版本为主，每季度评估 Zed RFC 进展
- **触发条件**: RFC #53403 Phase 2 (Panel API) 合并后启动开发
- **优势**: 风险最低，资源不浪费
- **劣势**: 错过早期市场窗口（但当前市场规模极小）

### 方案 E: 外部 TUI 工具 + Zed 集成（🟡 中长期方案）

- **工作量**: 1-2 个月
- **产出**: 独立的终端金融数据工具（如基于 tickrs/ticker），在 Zed 内置终端中使用
- **优势**: 不依赖 Zed API，跨编辑器通用
- **劣势**: 非原生集成，体验割裂

---

## 六、建议与结论

### 6.1 综合评估

| 维度 | 评分 | 说明 |
|------|------|------|
| 技术可行性 | ⭐⭐☆☆☆ | 当前 API 不支持核心功能 |
| 经济可行性 | ⭐☆☆☆☆ | 投入产出比极低 |
| 时间可行性 | ⭐⭐☆☆☆ | 最早 2026 Q3 有机会 |
| 生态匹配度 | ⭐⭐☆☆☆ | Zed 用户基数尚小 |
| 数据层复用度 | ⭐⭐⭐⭐☆ | 70% 逻辑可借鉴 |
| **综合评分** | **⭐⭐☆☆☆** | **不推荐当前投入** |

### 6.2 分级建议

**🔴 立即执行（零成本）**
1. 在 leek-fund 仓库创建 `zed-support` label，跟踪相关 issue
2. 订阅 RFC #53403 讨论，设置通知
3. 评估 MCP Server 方案的可行性（投入 1-2 天做技术验证）

**🟡 短期行动（1-4 周）**
4. 开发 leek-fund MCP Server（数据层封装），服务 Zed AI Agent 用户
5. 在 README 中添加 Zed 使用指南（通过 MCP 方式）

**🟢 中长期规划（6-12 个月）**
6. 当 RFC #53403 Phase 2 (Panel API) 合并后，启动简化版 Zed 插件开发
7. 当 Zed 用户基数显著增长（>10x 扩展数），重新评估完整移植 ROI

### 6.3 最终结论

> **leek-fund 在当前（2026-05）不适合改造为 Zed 插件。**
>
> Zed 的扩展 API 尚处于早期阶段，缺少 leek-fund 所需的全部核心 UI API（TreeView、StatusBar、WebView）。即使未来 RFC #53403 实现，走势图等 WebView 功能也因 Zed 的 GPUI 路线选择而无法直接迁移。
>
> **推荐策略**: 短期通过 MCP Server 方案服务 Zed 用户（投入 1-2 周），中长期持续跟踪 Zed API 演进，在 Panel API 落地后评估简化版插件开发。

---

## 附录：研究维度索引

| 维度 | 文件 | 核心结论 |
|------|------|---------|
| 01 - leek-fund 代码架构 | dim01.md | 68 文件，27,896 行 TS，8 大模块 |
| 02 - VS Code API 依赖 | dim02.md | 全面深度依赖所有核心 UI API |
| 03 - Zed API 能力 | dim03.md | v0.7.0，6 类功能，无 UI API |
| 04 - Zed UI 能力 | dim04.md | 完全不支持自定义 UI |
| 05 - Zed 技术栈 | dim05.md | Rust→WASM，无 JS/TS 支持 |
| 06 - 功能映射分析 | dim06.md | 80-90% 核心功能无法实现 |
| 07 - 数据层可复用性 | dim07.md | ~70% 数据逻辑可借鉴 |
| 08 - Zed 生态先例 | dim08.md | 金融插件完全空白 |
| 09 - 改造成本评估 | dim09.md | 6-12 个月，2-3 名 Rust 开发者 |
| 10 - 分发机制差异 | dim10.md | GitHub 子模块 PR 审核模式 |
| 交叉验证 | cross_verification.md | 10 维度结论高度一致，无冲突 |
| 洞察提取 | insight.md | 6 条跨维度非显性洞察 |
