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

## What to verify on a real device

- **Internet host** (e.g. `8.8.8.8`): replies over Wi-Fi and cellular.
- **LAN host** (e.g. your router): the iOS local network permission prompt
  should appear on first ping; after granting, replies arrive.
  Denying it makes sends fail or time out.
- **Suspend/resume**: start an unlimited ping, background the app for a
  minute, return. Expected: no events while suspended, then timeouts/replies
  resume; the socket keeps working. Note the observed behavior in
  `PLAN.md` §3 if it differs.

  ⚠️ Run this test **detached from Xcode** (launch from the Home Screen):
  with the debugger attached, iOS never suspends the app, so it keeps
  pinging in the background and the sequence number jumps by hundreds —
  which says nothing about real suspension behavior.
