@AGENTS.md

## Claude Code

上面一行导入 AGENTS.md —— 本仓库对所有 agent 的通用规则都在那里。本节只写 Claude Code 自己的默认行为与本仓库冲突、需要显式关掉的部分。

- **不要署名。** commit message 末尾不要 `Co-Authored-By: Claude ...`，PR 正文末尾不要 `🤖 Generated with Claude Code`，正文里也不要出现模型名、agent 模式或执行步骤。AGENTS.md 的 Repository First 已写明理由，这里再强调一次，是因为 Claude Code 的默认模板会自动补上这两行 —— 不特意去掉就会进仓库。
- **不要派 subagent。** 除非用户明确要求，本仓库的任务在主会话里直接做，上下文更连贯。
- **临时文件写 scratchpad。** 探针程序、抓包、对比输出、临时脚本不要落进仓库，也不要留在 `/tmp` 当长期证据；需要留存的证据按 AGENTS.md 贴进 issue 或 PR 正文。
- **skip 不是 pass。** 沙箱里的 Bash 可能拿不到非特权 ICMP socket，`swift test` 的 loopback 集成测试会按 AGENTS.md 的约定跳过而不是失败。看到 skip 就说 skip，不要把它当成验证通过；真要验证收发路径，在沙箱外重跑或在设备上跑 `Examples/PingDemo`。
- **与用户对话用中文。**
