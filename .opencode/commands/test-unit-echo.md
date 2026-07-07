---
description: 编译并运行当前任务相关的单元测试，输出结果并分析失败原因
agent: build
---

## 🧪 单元测试执行

请按 Echo 项目 AGENTS.md 的测试契约（§9）和测试文件存放规范（§10.2 / §12.3）执行：

### 第一步：定位测试目标
1. 读取 `docs/05-planning/task-status.json`。
2. 如果用户指定了任务 ID（如 `test-unit-echo 2.1`），优先使用用户指定的。
3. 如果未指定，找到当前 `in_progress` 或 `review` 的任务。
4. **如果没有找到任务**：
   - 输出："当前没有进行中或待审查的任务。"
   - 列出所有 `ready` 状态的任务及其 test_file。
   - 询问用户是否要测试特定任务（请提供任务 ID）。
5. **如果任务的 `test_file` 为 `null`**：
   - 输出："该任务尚未配置测试文件。"
   - 提示用户是否需要创建测试文件，或继续使用其他方式测试。

### 第二步：运行测试
1. 确定测试目标：
   - 从 task-status.json 读取 test_file 路径（如 `EchoTests/Phase2/PrivacyActorTests.swift`）。
   - 从文件名提取测试套件名（类名，如 `PrivacyActorTests`）。
   - 注意：Echo 项目的测试文件按阶段存放在 `EchoTests/Phase{N}/` 目录下。
2. 执行测试：
   ```bash
   xcodebuild test -project Echo.xcodeproj -scheme Echo \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
     -only-testing:EchoTests/[测试套件名]
   ```
3. **扩展选项**：
   - 如果用户传递了 `--all` 参数，运行当前模块的所有测试。
   - 如果用户传递了 `--full` 参数，运行所有单元测试（全量）。

### 第三步：结果分析
1. **成功**：
   - 输出测试通过数量。
   - 提示可查看 `.xcresult` 文件获取覆盖率数据。
2. **失败**：
   - 解析失败堆栈，定位失败测试方法。
   - 引用相关的 AC 原文，检查是代码逻辑错误还是测试本身过时。
   - 提出修复建议（但不自动修改代码，除非用户明确要求）。

### 第四步：更新状态
1. 测试通过后，输出 ✅ 标记，显示通过用例数/总用例数。
2. 如果用户要求，将测试结果记录到 PR 描述中（可选）。