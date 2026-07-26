# UIAutomation/Artifacts

本目录保存 UI 自动化运行的执行证据。

## 目录约定

```
Artifacts/
├── manifests/          # run manifest JSON
├── summaries/          # 结构化测试摘要
├── accessibility/      # accessibility tree
├── logs/               # raw build/test/run logs
├── xcresults/          # .xcresult bundles
└── crashes/            # crash reports
```

## 严格禁止

- ❌ Screenshots (PNG)
- ❌ Reference/actual/diff images
- ❌ Videos (MP4, GIF)
- ❌ Screen recordings
- ❌ 任何持久化视觉媒体

## 保留策略

| 产物 | 策略 |
|------|------|
| manifest + 结构化摘要 + accessibility tree + 必要日志 | 持久化 |
| 通过的 `.xcresult` | 摘要写入 manifest 后可删除 |
| 失败的 `.xcresult` | 保留至 blocker 解决或任务完成 |
| CI artifact | 短期 retention，不提交到 Git |

## Run Manifest 必需字段

参见 `docs/ui/testing-and-artifacts.md` §3。
