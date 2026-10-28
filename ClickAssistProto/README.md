# ClickAssistProto

Standalone proof-of-concept for click-assist: a **mutable** `CGEventTap`
(`kCGEventTapOptionDefault`) that rewrites an incoming mouse event's location with
`CGEventSetLocation` and returns the modified event, so the WindowServer / AppKit
hit-test uses the corrected coordinate. No listen-only tap, no NULL-swallow, no
`CGEventPost` repost.

```bash
swift build -c release
.build/release/ClickAssistProto --selftest
.build/release/ClickAssistProto            # interactive demo window
```

Flags: `--tolerance <pt>` (default 12), `--tap-point hid|session`,
`--simulate-untrusted` (exercise the pre-TCC pass-through path).

Requires Accessibility trust for the tap; the process calls
`AXIsProcessTrustedWithPrompt` and runs pure pass-through until granted.
Files here are additions only; no Mousecape target is touched.
