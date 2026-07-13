# Swift Ping 库规划（PingKit）

> 状态：M1–M8 已完成，当前版本 0.3.0；0.4.0 待发布，IPv6 进入 0.5.0。更新日期：2026-07-14

## 1. 背景与现有生态

| 方案 | 状态 | 结论 |
|---|---|---|
| Apple **SimplePing**（官方示例） | Objective-C，最后更新 2016（v1.4 加入 IPv6），已归档 | 不是库，但是"免特权 ICMP socket"做法的权威参考实现，协议细节（校验和、IPv4 收包带 IP 头等）值得照抄 |
| **SwiftyPing**（samiyr） | MIT，单文件 Swift 5，最后发版 v1.2.1（2021） | 社区最流行，但基本停更；回调式 API、无 async/await、无 Swift 6 并发安全、作者自述"unsafe cast 可能不优雅地失败" |
| **SwiftPing**（ankitthakur）等 | 更老，弃维护 | 不考虑 |
| **swift-nio** `NIORawSocketBootstrap` | 活跃 | 走 SOCK_RAW，需要 root/CAP_NET_RAW，不适合 iOS/沙盒 App；依赖也重 |
| **Network.framework** | 官方现代网络栈 | **不支持 ICMP**。只能用 TCP/UDP 连接耗时模拟"ping"，不是真 ping |

**结论：没有可以直接依赖的、现代化的官方或社区库。** 生态里存在明显空档：一个 Swift 6、async/await、strict concurrency、零依赖的 ICMP ping 库。这正是本项目的定位。

首版聚焦 **IPv4 Echo Request/Reply**。2026-07-14 已确认 Pingman 与 IPv6-only / NAT64 审核网络的真实需求，因此后续里程碑补齐 ICMPv6 Echo、双栈解析与 hop-limit 元数据；IPv6 traceroute 仍不在本阶段范围。

## 2. 技术路线选型

**推荐：免特权 ICMP datagram socket（SimplePing 同款方案），自己实现协议层。**

```c
socket(AF_INET,  SOCK_DGRAM, IPPROTO_ICMP)    // IPv4
socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)  // IPv6
```

- 目标平台为 macOS 13+ / iOS 16+；使用免特权 ICMP datagram socket 发送/接收 IPv4 与 IPv6 Echo Request/Reply。
- 不依赖 SwiftNIO，包保持零依赖。
- 事件驱动层不用 CFSocket（SimplePing 的老做法），改用 **DispatchSourceRead / DispatchIO** 包一层，再在其上暴露 async API；这样 Linux（swift-corelibs 有 Dispatch）也能复用。

备选路线（记录但不采用）：
- SOCK_RAW：功能最全（可自定义 TTL 探测做 traceroute），但需要 root，iOS 不可用。可作为将来 macOS-only 的可选后端。
- NWConnection TCP/UDP 探活：不是 ICMP，仅可作为 fallback 特性（`TCPPing`）放到远期。

## 3. 平台差异备忘（实现时的坑）

- **macOS/iOS IPv4 收包**：SOCK_DGRAM ICMP socket 收到的数据**包含完整 IP 头**（和 SOCK_RAW 一样），需要先按 IHL 跳过 IP 头再解析 ICMP。TTL 从 IPv4 头读取。
- **IPv6 收包**：ICMPv6 socket 返回裸 ICMPv6 消息；源地址从 `recvmsg.msg_name` 读取，hop limit 通过 `IPV6_RECVHOPLIMIT` / `IPV6_HOPLIMIT` ancillary data 获取。
- **ICMPv6 校验和**：包含 IPv6 pseudo-header，datagram socket 由内核在发送/接收路径计算与验证；库构造请求时 checksum 字段保持 0。
- **Identifier 字段**：Darwin 上保留应用设置的 identifier；Linux 上内核会把 ICMP id 重写为 socket 的"端口号"，匹配回包时不能依赖自己写入的 id，要以内核为准。
- **Linux 权限**：免特权 ICMP 需要 `net.ipv4.ping_group_range` sysctl 覆盖进程 gid（多数发行版默认不开），否则需要 CAP_NET_RAW。IPv4 Echo 已纳入持续 CI；Traceroute 中间跳仍受 error queue 限制。
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
- DNS 解析用 `getaddrinfo(AF_UNSPEC)` 获取系统排序后的 A / AAAA 结果，并在线程池中执行；`.automatic` 采用首个结果以兼容 DNS64/NAT64，亦可强制 `.ipv4` / `.ipv6`。
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

平台目标：macOS 13+ / iOS 16+（为了 `Duration`/Swift 并发）。Linux 的 IPv4 / IPv6 Echo 持续验证，Traceroute 为 IPv4 best-effort；tvOS、watchOS、visionOS 暂不承诺。

## 6. 里程碑

1. ✅ **M1 协议层（纯逻辑）**：ICMP echo 包编码/解码、checksum、IPv4 头剥离。全部纯函数 + 单元测试（含畸形包 fuzz 样例）。
2. ✅ **M2 IPv4 单发**：socket 封装、DispatchSource 收包、`Pinger.ping(_:)` 一次性 API 在 macOS 跑通；ping-cli 出雏形。
3. ✅ **M3 连续 ping**：AsyncSequence、interval/timeout/count、序号匹配与去重（重复/乱序回包）、统计。
4. ✅ **M4 生命周期与错误语义**：Task cancellation、迭代终止、显式 `stop()`、ICMPv4 差错报文映射。
5. ✅ **M5 CI 与 Linux 验证**（macOS + Linux 双平台全绿；Linux 在特权容器内跑通真实 loopback 集成测试。Glibc 分支已完成条件编译修正：变参 `fcntl` 不可从 Swift 调用，因此 `O_NONBLOCK` 仅在 Darwin 设置）
   - GitHub Actions 三个 job：
     - macOS：`swift build && swift test`（集成测试在 runner 上可直接跑 loopback）。
     - Linux：ubuntu runner + Swift 6 工具链；先 `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"` 打开免特权 ICMP，再 `swift test`。这样 Linux 从"best-effort 未编译验证"直接升级为 CI 持续验证。
     - Glibc 分支已在 CI 编译并测试，覆盖 `SOCK_DGRAM` 枚举和常量类型差异。
   - 顺手加 LICENSE（MIT）和 README badge。
6. ✅ **M6 首次发布**（`0.1.0` 与 GitHub Release 已发布；DocC catalog 本地构建通过；`.spi.yml` 就绪。当前最新版本为 `0.3.0`。**遗留**：Swift Package Index 收录需要仓库先转 public 并到 swiftpackageindex.com/add-a-package 提交，由仓库所有者操作）
7. ✅ **M7 iOS 验证**
   - ✅ CI 加 iOS 门禁：`generic/platform=iOS` 设备目标编译 + iOS 模拟器全量测试（含 loopback 集成测试，证明 ICMP dgram socket 在 iOS 运行时可用）。
   - ✅ 最小 SwiftUI demo App（`Examples/PingDemo`，xcodegen 生成工程，含 `NSLocalNetworkUsageDescription`），模拟器构建通过。
   - 真机实测结果（2026-07-13，iPhone 真机）：
     - ✅ Wi-Fi / 蜂窝下 ping 外网正常。
     - ✅ ping 局域网地址（路由器）首次触发 iOS 本地网络权限弹窗，授权后正常收到回包。
     - ⚠️ 调试器附加时 iOS 不挂起 App——实测从 seq 9 退后台约 8 分钟，回前台已到 seq 500+（后台持续发包），此为调试环境行为，不代表真实语义。
     - ✅ 脱离调试器复测结论：**iOS 对后台 App 无存活承诺**——短期退后台进程即可能被系统终止（回前台是全新启动），长期后台必被杀。因此库的使用契约是：ping 会话不跨后台存活，退后台时 `stop()`、回前台重开（demo 已用 `scenePhase` 演示该模式）；进程被直接终止时 socket 由内核回收，无泄漏问题。M7 关闭。
8. ✅ **M8 IPv6 Ping**（进 0.5.0，breaking）
   - `ICMPv6` Echo 与 RFC 4443 四类差错解析；`ICMPv6Socket` 支持源地址、hop limit 与发送 hop limit。
   - `IPAddress` / `IPv6Endpoint` 与 scoped link-local 地址；`PingReply.from` 从 IPv4-only 升级为双栈地址。
   - `PingConfiguration.AddressFamily` 提供 `.automatic` / `.ipv4` / `.ipv6`；automatic 遵循系统 `getaddrinfo` 排序，覆盖 DNS64/NAT64。
   - macOS 真实 `::1` 集成测试通过；CLI 增加 `-4` / `-6`。IPv6 traceroute 明确留待后续。

## 6.1 0.2.0 已发布能力

- ✅ **traceroute 模式**（已实现，进 0.2.0）：`Tracer` actor + `hops` AsyncSequence，`IP_TTL` 逐跳探测，Time Exceeded/Echo Reply/Unreachable 三类终止语义；CLI `ping-cli trace`。实测 8.8.8.8 十五跳路径正确。注意：Linux 内核把 ICMP 差错投递到 socket error queue（MSG_ERRQUEUE），当前未读取，Linux 上中间跳显示为超时，终点仍可达——如需完整 Linux 支持需实现 error queue 读取，暂记 backlog。
- ✅ **RTT 精度增强**（已实现，进 0.2.0）：Darwin 用 `SO_TIMESTAMP_MONOTONIC` 内核收包时间戳（`SCM_TIMESTAMP_MONOTONIC` cmsg，mach ticks × timebase 换算 ns），与发送侧 `CLOCK_UPTIME_RAW` 同基准；Linux 统一为 `CLOCK_MONOTONIC` 读取时刻兜底。`MonotonicTimestamp` 取代 `ContinuousClock.Instant` 贯穿 socket 协议。实测 loopback：唤醒延迟约 0.18ms 被消除，平均 RTT 0.34ms → 0.10ms，stddev 0.13 → 0.02ms。

## 6.2 0.3.0 已发布能力

- ✅ **收包保序**（已实现，进 0.3.0）：socket 回调先进入单一 `AsyncStream` 管道，再由一个任务依次投递给 `Pinger` / `Tracer` actor，避免 unstructured Task 竞争导致乱序；突发 100 个回包的回归测试覆盖该行为。
- ✅ **公开 API 收敛**（已实现，进 0.3.0，breaking）：仅用于内部测试注入的 `PingSocket`、`SocketFactory`、`HostResolver` 和 `MonotonicTimestamp` 不再暴露为公共契约。
- ✅ **单消费者错误统一**（已实现，进 0.3.0，breaking）：`PingError.responsesAlreadyConsumed` 重命名为 `sequenceAlreadyConsumed`，同时适用于 `Pinger.responses` 与 `Tracer.hops`，不再携带错误的 Pinger 专属文案。

## 6.3 0.4.0 待发布能力

- ✅ **出包 TTL 配置**（进 0.4.0）：`PingConfiguration.timeToLive`（1...255，默认 `nil` 走系统默认），启动时经 `PingSocket.setTimeToLive` 应用到 socket，setsockopt 失败在首个 `next()` 上抛 `socketOptionFailed`。CLI ping 模式增加 `-m ttl`（对齐 `ping(8)`）。实测 `-m 1` 打 8.8.8.8 全部收到网关 Time Exceeded。
- ✅ **`.sent` 事件**（进 0.4.0，breaking）：`PingResponse` 新增 `.sent(sequence:)`，每个探测包发出后、终态事件（reply/timeout/unreachable/timeExceeded）之前投递，供 UI 实现"发包即插 pending 行、回包原位更新"（Pingman 迁移的核心 UX）。`Pinger.ping` 一次性 API 自动跳过该事件；demo App 已改为 pending 行模式。消费方的 `switch` 需新增 case。

## 6.4 0.5.0 待发布能力

- ✅ **IPv6 Ping**：完整内容见 M8；这是 `PingReply.from` 类型变化与 `PingResponse` 新增 ICMPv6 差错 case 的 breaking minor release。

## 6.5 Backlog（有价值但不排期）

- **Linux Traceroute 完整中间跳**：读取 ICMP socket error queue（`MSG_ERRQUEUE`）。
- **IPv6 Traceroute**：在 IPv4 traceroute 的 Linux error queue 缺口解决后，再统一设计双栈 traceroute 地址与错误语义。
- **可插拔 Socket 后端（0.4 候选）**：先观察 0.3 的公开 API 收敛反馈；仅当出现自定义传输、外部 Mock、`SOCK_RAW` 或其他后端的真实需求时，重新设计并开放稳定的注入 API，不直接恢复当前内部协议。进入 0.4 的前置条件是至少一个可复现的外部使用场景，并明确生命周期、并发安全和错误语义；没有真实需求则继续留在 Backlog。
- **`Pinger` 复用语义**：当前一个实例一次运行；如用户反馈需要 reset/restart，再评估。

## 7. 测试策略

- 协议层纯函数直接单测（黄金样本：用 tcpdump 抓真实 ping 包做 fixture）。
- Socket 层通过内部 `PingSocket` 协议，用 mock 注入回包/超时/差错报文，测状态机；若未来开放注入 API，需按 0.4 候选项重新设计公共契约。
- 集成测试 ping `127.0.0.1` 与 `::1`；测试前先探测对应 ICMP datagram socket 能力，不支持时明确 skip，不能把权限问题误判为功能回归。外网目标只放本地手动测试。
- 生命周期测试覆盖 Task cancellation、提前退出迭代、显式 `stop()`、重复关闭和第二消费者接入，验证后台发送任务与 socket 均被释放。

## 8. 风险

- Linux 的 ping_group_range 默认关闭 → 文档写清楚，报错信息要能指路。
- `getaddrinfo` 本身是阻塞调用，需要受控线程池与取消后的结果丢弃机制。
- App Store 审核对 ICMP 无限制先例（SwiftyPing 用户众多），风险低。
- NAT64 只保证域名通过 DNS64 获得合成 AAAA；IPv4 字面量无法在 IPv6-only 网络直接使用，调用方应展示可理解的解析/网络错误。

## 参考

- Apple SimplePing（归档示例）: https://developer.apple.com/library/archive/samplecode/SimplePing/
- SwiftyPing: https://github.com/samiyr/SwiftyPing
- Swift Forums – 免 root 收发 IP 包讨论: https://forums.swift.org/t/enabling-ip-packet-sending-receiving-in-swift-without-root-privilege/67123
- Linux 免特权 ICMP socket: https://lwn.net/Articles/422330/
- RFC 4443 – ICMPv6: https://www.rfc-editor.org/rfc/rfc4443
- RFC 6724 – Default Address Selection: https://www.rfc-editor.org/rfc/rfc6724
- macOS `icmp(4)` man page: https://keith.github.io/xcode-man-pages/icmp.4.html
