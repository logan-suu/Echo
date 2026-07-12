---
description: 运行项目的所有集成测试（全量回归），生成完整报告
agent: build
---

## 🌐 全量集成测试

请按 Echo 项目 AGENTS.md 的 CI 门禁清单（§9.3）执行：

### 第一步：前置检查与执行
0. **前置条件检查**：
   - 检查代码是否能编译：
     ```bash
     xcodebuild build -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
     ```
   - 如果编译失败，输出错误，建议先修复编译问题。
1. 运行所有测试（包括所有 Phase 的单元测试和集成测试）：
    ```bash
    xcodebuild test -project Echo.xcodeproj -scheme Echo \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -parallel-testing-enabled NO
    ```
2. 测试文件按阶段分布于 `EchoTests/Phase1/` ~ `EchoTests/Phase5/`。

### 第二步：性能与质量监控
1. 除了测试通过率，重点检查：
   - **跨语言召回率**：如果 Golden Dataset 测试包含在内，确保 Recall@10 ≥ 85%。
   - **延迟检查**：确保检索 P95 < 200ms（如果性能测试集成在测试套件中）。
2. 生成测试报告摘要，包含：
   - 总用例数、通过数、失败数。
   - 失败用例名称及涉及模块。
3. **不达标处理**：
   - **跨语言召回率 < 85%**：🔴 阻断，输出“召回率不达标，请优化模型或检索策略后再试。”
   - **检索 P95 ≥ 200ms**：🟡 警告，输出“性能有退化风险，建议优化后再发布。”
   - 如果用户仍要继续，需要明确输入“确认忽略”或“强制通过”。

### 第三步：对比基线
1. 查找上次测试日志：
   - 优先检查 `docs/05-planning/test-logs/integration-latest.md`
   - 如果没有，检查 `docs/05-planning/test-logs/integration-[日期].md`
   - 如果都没有，提示：“未找到历史测试日志，本次结果将作为基线。”
2. 对比差异：
   - 新增失败用例 → 分析是否由本次变更引起
   - 通过率变化 → 标记为 ⚠️ 或 🔴
3. 如果发现新增失败，分析是否由本次变更引起。

### 第四步：输出报告
1. **输出到对话**：在 OpenCode 对话中以 Markdown 表格形式展示报告。
2. **输出到文件**：将报告保存到 `docs/05-planning/test-logs/integration-[YYYY-MM-DD].md`。
3. **如果存在 PR**：将报告摘要评论到当前 PR 中。
4. 输出格式：
   ```markdown
   ## 🌐 全量集成测试报告
   | 指标 | 结果 | 状态 |
   | --- | --- | --- |
   | 总用例数 | X | - |
   | 通过数 | X | - |
   | 失败数 | X | ✅/❌ |
   | 通过率 | X% | ✅/❌ |
   | 跨语言召回率 | X% | ✅/❌ (≥85%) |
   | 检索 P95 | Xms | ✅/⚠️/❌ (<200ms) |
   | 新增失败 | [无 / 列表] | - |
   ```

### 第五步：后续操作
1. **全部通过**：输出 ✅，提示“全量集成测试通过，可进入发布流程。”
2. **部分失败**：
   - 输出失败用例列表。
   - 提供选项：
     - A：修复失败后重新运行 `test-integration-echo`
     - B：标记为已知问题，继续（需人类确认并记录）
     - C：跳过本次测试（仅限非关键路径）


