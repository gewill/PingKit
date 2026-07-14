# PingDemo

Minimal SwiftUI app for exercising PingKit on iOS devices. The Xcode project
is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and not
checked in:

```
brew install xcodegen
cd Examples/PingDemo
xcodegen
open PingDemo.xcodeproj
```

Set your signing team, then run on a device.

The **Auto / IPv4 / IPv6** picker maps to `PingConfiguration.AddressFamily`.
Auto follows the system's DNS ordering (so hostnames resolve over DNS64/NAT64);
each reply row shows the source address it came `from`, making the resolved
family visible.

## What to verify on a real device

- **Internet host** (e.g. `8.8.8.8`): replies over Wi-Fi and cellular.
- **IPv6**: ping `::1` (or a hostname with the picker on IPv6); reply rows
  show an IPv6 `from` address.
- **NAT64 / IPv6-only network**: on Auto, `8.8.8.8` should still reply from a
  synthesized IPv6 source; forcing IPv4 should fail or time out.
- **LAN host** (e.g. your router): the iOS local network permission prompt
  should appear on first ping; after granting, replies arrive.
  Denying it makes sends fail or time out.
- **Backgrounding**: start an unlimited ping, then background the app.
  Expected: the demo immediately stops the session. iOS does not promise that
  a backgrounded process will survive, so return to the app and start a new
  session instead of attempting to resume the old socket.

  ⚠️ Run this test **detached from Xcode** (launch from the Home Screen):
  with the debugger attached, iOS never suspends the app, so it keeps
  pinging in the background and the sequence number jumps by hundreds —
  which says nothing about real suspension behavior.
