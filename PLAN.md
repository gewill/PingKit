# Swift Ping 库规划（PingKit）

> 状态：开发中，M1–M4 已完成，M5 待实施。日期：2026-07-12

## 1. 背景与现有生态

| 方案 | 状态 | 结论 |
|---|---|---|
| Apple **SimplePing**（官方示例） | Objective-C，最后更新 2016（v1.4 加入 IPv6），已归档 | 不是库，但是"免特权 ICMP socket"做法的权威参考实现，协议细节（校验和、IPv4 收包带 IP 头等）值得照抄 |
| **SwiftyPing**（samiyr） | MIT，单文件 Swift 5，最后发版 v1.2.1（2021） | 社区最流行，但基本停更；回调式 API、无 async/await、无 Swift 6 并发安全、作者自述"unsafe cast 可能不优雅地失败" |
| **SwiftPing**（ankitthakur）等 | 更老，弃维护 | 不考虑 |
| **swift-nio** `NIORawSocketBootstrap` | 活跃 | 走 SOCK_RAW，需要 root/CAP_NET_RAW，不适合 iOS/沙盒 App；依赖也重 |
| **Network.framework** | 官方现代网络栈 | **不支持 ICMP**。只能用 TCP/UDP 连接耗时模拟"ping"，不是真 ping |

**结论：没有可以直接依赖的、现代化的官方或社区库。** 生态里存在明显空档：一个 Swift 6、async/await、strict concurrency、零依赖的 ICMP ping 库。这正是本项目的定位。

首版聚焦实际需求明确、实现路径成熟的 **IPv4 Echo Request/Reply**。IPv6 暂无真实使用场景或验收要求，不纳入首版承诺；待出现明确需求并完成平台验证后再规划。

## 2. 技术路线选型

**推荐：免特权 ICMP datagram socket（SimplePing 同款方案），自己实现协议层。**

```c
socket(AF_INET,  SOCK_DGRAM, IPPROTO_ICMP)    // IPv4
```

- 首版目标平台为 macOS 13+ / iOS 16+；使用免特权 ICMP datagram socket 发送/接收 IPv4 Echo Request/Reply。
- 不依赖 SwiftNIO，包保持零依赖。
- 事件驱动层不用 CFSocket（SimplePing 的老做法），改用 **DispatchSourceRead / DispatchIO** 包一层，再在其上暴露 async API；这样 Linux（swift-corelibs 有 Dispatch）也能复用。

备选路线（记录但不采用）：
- SOCK_RAW：功能最全（可自定义 TTL 探测做 traceroute），但需要 root，iOS 不可用。可作为将来 macOS-only 的可选后端。
- ICMPv6：暂无明确实际需求，待 IPv4 版本稳定且出现真实场景后单独设计和验证，不预先承诺双栈 API。
- NWConnection TCP/UDP 探活：不是 ICMP，仅可作为 fallback 特性（`TCPPing`）放到远期。

## 3. 平台差异备忘（实现时的坑）

- **macOS/iOS IPv4 收包**：SOCK_DGRAM ICMP socket 收到的数据**包含完整 IP 头**（和 SOCK_RAW 一样），需要先按 IHL 跳过 IP 头再解析 ICMP。TTL 从 IPv4 头读取。
- **Identifier 字段**：Darwin 上保留应用设置的 identifier；Linux 上内核会把 ICMP id 重写为 socket 的"端口号"，匹配回包时不能依赖自己写入的 id，要以内核为准。
- **Linux 权限**：免特权 ICMP 需要 `net.ipv4.ping_group_range` sysctl 覆盖进程 gid（多数发行版默认不开），否则需要 CAP_NET_RAW。Linux 支持列为 best-effort。
- **App Sandbox（macOS）**：需要 `com.apple.security.network.client`（发）和 `com.apple.security.network.server`（收）entitlement，README 要写清楚。
- **校验和**：IPv4 ICMP 校验和由库计算。
- **XNU 会改写 ICMP 差错报文（已实测踩坑）**：内核在把 type 3/11 差错报文投递给 socket 前，会原地把内嵌（quoted）IP 头的 `ip_len` 转成主机字节序（老 BSD 遗留行为），导致整个 ICMP 报文的校验和无法按收到的字节验证。因此校验和只对 echo reply/request 验证；差错报文靠"内嵌 identifier+sequence 匹配在途 probe"来鉴别。外层 IP 头的 `ip_len` 同样被改成主机序并减去了头长，不要依赖该字段。
- **解析不可信主机的回包**：所有字节到结构体的解析必须做边界检查，不用 `unsafeBitCast` 一把梭（SwiftyPing 的已知弱点）。

## 4. API 设计草案

Swift 6，公开值类型遵循 `Sendable`，核心是 actor + AsyncSequence。`responses` 是可跨 actor 使用的非隔离序列句柄；运行中的统计通过 actor 隔离方法读取：

```swift
// 一次性
let reply = try await Pinger.ping("example.com")   // -> PingReply(rtt:ttl:from:seq:)

// 连续 ping，AsyncSequence 风格
let pinger = Pinger(host: "1.1.1.1", configuration: .init(
    interval: .seconds(1),
    timeout: .seconds(2),
    count: .unlimited,          // 或 .times(5)
    payloadSize: 56
))

for try await response in pinger.responses {
    switch response {
    case .reply(let r):    print("\(r.sequence): \(r.roundTripTime)")
    case .timeout(let s):  print("\(s): timeout")
    }
}

// 统计
let stats = await pinger.statistics()   // sent/received/loss/min/avg/max/stddev(jitter)
```

要点：
- DNS 解析用 `getaddrinfo` 获取 A 记录，并在线程池中执行，避免阻塞 Swift cooperative thread。
- 错误模型：`PingError`（解析失败/socket 创建失败/权限不足/host unreachable/TTL exceeded…），把 ICMPv4 差错报文（type 3/11）映射为语义化错误而不是静默丢弃。
- 生命周期：Task cancellation 会停止发送、结束序列并关闭 socket；单纯退出 `for await` 不等同于取消 Task。序列通过终止回调通知 `Pinger` 停止，另提供幂等的 `await pinger.stop()` 作为明确关闭入口。
- 首版 `responses` 仅允许一个活跃消费者；重复订阅返回明确错误，避免多个迭代器争抢同一 socket 状态。

## 5. 包结构

```
Ping/
├── Package.swift            // swift-tools 6.0, 零第三方依赖
├── Sources/
│   ├── PingKit/             // 库本体
│   │   ├── Pinger.swift             // 公开 actor / API 门面
│   │   ├── PingConfiguration.swift
│   │   ├── PingReply.swift / PingError.swift / PingStatistics.swift
│   │   ├── ICMP/                    // 协议层：header 编解码、checksum（纯函数，易测）
│   │   ├── Socket/                  // socket 封装 + DispatchSource 事件层
│   │   └── Resolver/                // getaddrinfo 封装
│   └── ping-cli/            // 可执行 demo（ArgumentParser 可选，或手写参数解析保持零依赖）
└── Tests/PingKitTests/
```

首版平台目标：macOS 13+ / iOS 16+（为了 `Duration`/Swift 并发）。Linux 为 best-effort；IPv6、tvOS、watchOS、visionOS 暂不承诺。

## 6. 里程碑

1. ✅ **M1 协议层（纯逻辑）**：ICMP echo 包编码/解码、checksum、IPv4 头剥离。全部纯函数 + 单元测试（含畸形包 fuzz 样例）。
2. ✅ **M2 IPv4 单发**：socket 封装、DispatchSource 收包、`Pinger.ping(_:)` 一次性 API 在 macOS 跑通；ping-cli 出雏形。
3. ✅ **M3 连续 ping**：AsyncSequence、interval/timeout/count、序号匹配与去重（重复/乱序回包）、统计。
4. ✅ **M4 生命周期与错误语义**：Task cancellation、迭代终止、显式 `stop()`、ICMPv4 差错报文映射。
5. ⏳ **M5 CI 与 Linux 验证**（下一步，优先级最高）
   - GitHub Actions 两个 job：
     - macOS：`swift build && swift test`（集成测试在 runner 上可直接跑 loopback）。
     - Linux：ubuntu runner + Swift 6 工具链；先 `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"` 打开免特权 ICMP，再 `swift test`。这样 Linux 从"best-effort 未编译验证"直接升级为 CI 持续验证。
     - Glibc 分支从未实际编译过，预期要修一轮条件编译小错（SOCK_DGRAM 枚举、常量类型差异）。
   - 顺手加 LICENSE（MIT）和 README badge。
6. ⏳ **M6 发布 v0.1.0**
   - DocC catalog（API 注释已基本齐备），Swift Package Index 收录并启用其托管文档。
   - SemVer 打 tag `0.1.0`；README 写清楚稳定性承诺（0.x 阶段 API 可能调整）。
7. ⏳ **M7 iOS 验证**
   - CI 加 `xcodebuild -destination 'generic/platform=iOS'` 编译门禁。
   - 最小 SwiftUI demo App 真机验证：Wi-Fi / 蜂窝、App 进后台挂起后 socket 与在途 probe 的行为（预期：suspend 后 DispatchSource 停摆，恢复后超时补发，需实测确认语义并写进文档）。
   - 确认 ping 局域网地址是否触发 iOS 14+ 本地网络权限弹窗，README 补充 `NSLocalNetworkUsageDescription` 指引。

IPv6 作为独立后续里程碑：仅在出现真实需求后，补充 ICMPv6 协议、hop-limit ancillary data、双栈地址选择策略和对应平台测试，不影响首版交付。

## 6.1 Backlog（有价值但不排期）

- **traceroute 模式**：ICMP dgram socket 支持 `setsockopt(IP_TTL)`，且 type 11 Time Exceeded 的解析/映射已经就绪，逐跳探测是 v0.2 的自然候选特性。
- **RTT 精度增强**：用 `SO_TIMESTAMP` 内核时间戳替代用户态 `ContinuousClock`，消除调度抖动。
- **收包保序**：目前 socket 回调用无序 unstructured Task 投递进 actor，突发回包理论上可能乱序进入流（间隔式 ping 实际影响可忽略）。如需严格保序，可改为 AsyncStream 管道单任务消费。已知限制，先记录。
- **`Pinger` 复用语义**：当前一个实例一次运行；如用户反馈需要 reset/restart，再评估。

## 7. 测试策略

- 协议层纯函数直接单测（黄金样本：用 tcpdump 抓真实 ping 包做 fixture）。
- Socket 层抽 `PingSocketProtocol`，用 mock 注入回包/超时/差错报文，测状态机。
- 集成测试 ping `127.0.0.1`；测试前先探测 ICMP datagram socket 能力，不支持时明确 skip，不能把权限问题误判为功能回归。外网目标只放本地手动测试。
- 生命周期测试覆盖 Task cancellation、提前退出迭代、显式 `stop()`、重复关闭和第二消费者接入，验证后台发送任务与 socket 均被释放。

## 8. 风险

- Linux 的 ping_group_range 默认关闭 → 文档写清楚，报错信息要能指路。
- `getaddrinfo` 本身是阻塞调用，需要受控线程池与取消后的结果丢弃机制。
- App Store 审核对 ICMP 无限制先例（SwiftyPing 用户众多），风险低。

## 参考

- Apple SimplePing（归档示例）: https://developer.apple.com/library/archive/samplecode/SimplePing/
- SwiftyPing: https://github.com/samiyr/SwiftyPing
- Swift Forums – 免 root 收发 IP 包讨论: https://forums.swift.org/t/enabling-ip-packet-sending-receiving-in-swift-without-root-privilege/67123
- Linux 免特权 ICMP socket: https://lwn.net/Articles/422330/
- macOS `icmp(4)` man page: https://keith.github.io/xcode-man-pages/icmp.4.html
