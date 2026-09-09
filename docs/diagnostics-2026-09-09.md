# 项目诊断：2026-09-09

基线：`356ee1c`（0.6.2）。覆盖库、CLI、测试、Demo、公开文档与 CI 配置。本次仅诊断，未修改实现。

## 验证范围

- macOS 26.6.2 / Apple Silicon / Swift 6.3.3：`swift test` 构建成功，72 项测试通过，IPv4、IPv6 与 traceroute 的真实回环测试均执行，未跳过。
- 系统基准：`ping -c 1 127.0.0.1`、`ping6 -c 1 ::1`、`traceroute -n -q 1 -m 2 127.0.0.1` 均正常。
- 边界复现使用当前库对象文件和已有 `MockPingSocket` / `BurstReplySocket`，无需修改生产代码。
- 本次未运行 iOS 构建、模拟器、真机或 Linux 测试；这些平台只做静态检查。未验证 NAT64、权限弹窗及后台行为。

## 功能问题

### P2：在途探针跨越序号回绕时，有限次数运行不能结束

位置：`Sources/PingKit/Pinger.swift:246`、`:297`、`:405`、`:429`。

`sequence` 是循环递增的 `UInt16`，`pending` 也只以它为键。第 65,537 次发送复用序号 0；若第一轮序号 0 仍在等待，字典直接覆盖旧探针。旧探针没有终态，旧 timeout 任务也没有取消；其超时回调甚至可能移除新一轮同序号探针。最终 `completed` 无法达到配置次数。

复现方式：使用已有 `BurstReplySocket(replyCount: count)`，配置 `interval: .nanoseconds(1)`、`timeout: .seconds(60)`、`payloadSize: 0`，等所有请求在途后依发送顺序注入全部回包。只改变 count，结果如下：

| count | sent | terminal | 自然结束 |
|---|---:|---:|---|
| 65,536 | 65,536 | 65,536 | 是 |
| 65,537 | 65,537 | 65,536 | 否，需显式 stop |

65,537 的失败结果重复复现两次。该问题要求旧探针尚未完成时发生回绕；普通配置运行到回绕并不必然触发。

建议：禁止覆盖仍在途的序号；明确容量达到 65,536 时的行为，并让超时回调校验探针代次。回包的跨轮次区分还需单独设计，不能只扩大内部字典键而忽略报文中的 16 位序号。

### P2：回包缺少目标归属校验，标识碰撞时可能串线

位置：`Sources/PingKit/Pinger.swift:367`、`Sources/PingKit/Traceroute/Tracer.swift:241`。

Darwin 分支只检查 identifier 与 sequence，没有核对 Echo Reply 的源地址是否属于本次单播目标。identifier 随机选自 16 位空间，多个运行可能碰撞。Tracer 也会将匹配这两个字段的 Echo Reply 直接判定为到达终点。

两层验证：

- 实际创建两个 Darwin 免特权 IPv4 ICMP datagram socket；一个向 `127.0.0.1` 发送，另一个完全没有发送，也收到相同 identifier/sequence 的 Echo Reply。内核不会替当前未连接的 socket 隔离会话，这与 [XNU 的 raw IP 分发逻辑](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/raw_ip.c) 一致。
- 用 `MockPingSocket` 返回 identifier/sequence 正确、源地址为 `192.0.2.1` 的合成回包；解析目标保持 `127.0.0.1`。当前库输出 `accepted_source=192.0.2.1 received=1`。

这证明标识碰撞后的错误接收路径；本次没有依赖随机碰撞去宣称实测了多会话串线。Tracer 的同类风险来自静态检查。

建议：先补单播 Echo Reply 的来源校验，再检查差错报文内嵌的目标地址；中间路由器的差错源地址不能直接与终点比较。同目标并发运行的标识冲突仍需会话或 payload 标识策略。Linux 必须保留内核改写 identifier 的适配。

### P2：CLI 接受无法转换为 Duration 的数值并崩溃

位置：`Sources/PingKitCLI/PingKitCommand.swift:57`、`:69`、`:159`、`:169`。

时间参数只检查 `> 0`。正无穷与过大的有限 Double 都能通过，随后 `.seconds(...)` 触发整数转换断言。

复现命令（先执行 `swift build`）：

```sh
.build/debug/pingkit-cli 127.0.0.1 -c 1 -i inf
.build/debug/pingkit-cli 127.0.0.1 -c 1 -W 1e100
.build/debug/pingkit-cli trace 127.0.0.1 -W inf
```

三条命令均以 SIGTRAP 终止，错误为 `Double value cannot be converted to _Int128 because it is outside the representable range`。系统 `ping -i inf` 与 `traceroute -w inf` 均正常报告参数错误并退出。

建议：转换前校验 `isFinite` 及安全上限；仅补 `isFinite` 仍不能拦截 `1e100`。增加覆盖 ping interval、ping timeout、trace timeout 的参数边界用例。

## 文档错误

### P3：README 仍称仓库私有

位置：`README.md:46`。

`gh repo view --json nameWithOwner,visibility` 返回 `gewill/PingKit` / `PUBLIC`，与 PLAN 的公开发布记录一致。README 却要求消费者提供私有仓库凭据，可能误导安装。建议删除这段过期说明。

## 值得做的优化

1. **收包内存与流缓冲。** `ICMPv4Socket.swift:122` 和 `ICMPv6Socket.swift:158` 每次收包都分配并清零 65,535 字节数组，`removeLast` 后仍保留容量。真实 IPv4 回环观测：`bytes.count = 84`、`bytes.capacity = 81888`；容量数值依分配器而异。接收与响应流又采用默认无界缓冲（[Swift AsyncStream 定义](https://github.com/swiftlang/swift/blob/main/stdlib/public/Concurrency/AsyncStream.swift)）。突发收包或慢消费者会放大内存占用。建议复用 socket 队列内的接收存储，只把有效数据交给 actor，并为积压制定明确策略；公开事件不能直接改为静默丢弃，否则会破坏 sent/终态配对。本次确认了容量保留，未做吞吐或峰值内存基准。
2. **Demo 历史行上限。** `Examples/PingDemo/Sources/ContentView.swift:183` 无限向数组头部插入，每次回复还扫描整个数组找 pending 行。长时间运行时存储和更新成本持续增长。建议保留最近固定数量的结果，并同步处理被裁剪的 pending 引用；本次为静态优化建议，未声称实测 UI 卡顿。
3. **CI 集成测试门禁。** `.github/workflows/ci.yml:57` 在设置 ICMP 权限失败时仍返回成功，能力探测又会跳过集成测试。建议本地保留环境受限时的 skip，正式 CI 则要求回环能力具备且集成测试实际执行，防止将来出现只跑单测的绿灯。本次 macOS 集成测试没有跳过。

Linux error queue 与 IPv6 traceroute 已在 PLAN 中列为能力缺口，继续按既有 backlog 推进。当前证据不支持为这些发现重写 actor/socket 架构或引入新依赖。
