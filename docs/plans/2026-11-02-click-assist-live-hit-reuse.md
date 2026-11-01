# Click Assist direct-seed publication implementation plan

**Goal:** Reduce time to a confirmed ring without changing click delivery, evidence expiry or target admission.

**Architecture:** A fresh first-class control outside a native list context directly under the pointer may defer redundant window discovery only after a separate strong legitimacy proof. The merged union still runs the original winner selection and final legitimacy check; the preliminary proof cannot populate its cache. Nearby, weak, unknown and empty seeds retain normal discovery. At most four consecutive local-only cycles are permitted before broader discovery resumes.

**Tech stack:** Swift, ApplicationServices AX, existing XPC snapshots and native overlay.

1. Capture baseline resolver/walk/evidence timings during live target transitions. Measure proposed redundant-query savings before implementing.
2. Ship only the material optimization: verified direct-seed priority. Preserve periodic broader discovery and all final checks.
3. Exercise uncertainty, outside-target, secondary-tier and periodic-discovery behavior in the semantic regression suite.
4. Run all three project builds; sign/install and verify running binaries.
5. Compare live timings and verify actual rings/clicks on Brave tabs/close, OpenCode, YouTube normal/full-screen, MyHome and desktop menus. Record uncovered cases honestly. Do not commit without user request.

Baseline investigation: repeated system-wide AX hits cost a median ~0.27 ms in Brave (314 successful pairs); this optimization was discarded before installation. Synthetic duplicate-frame filtering did not improve performance and was not applied. Live baseline-ready capture contains 502 Brave cycles with median pre-evidence resolver time 50.22 ms. It contains no OpenCode or MyHome cycles, so those are not baseline-verified.

Live first-build capture found two native-row selection rejections (AX error -25204). The final shortcut excludes every seed containing a native selectable row or native row button; these contexts retain their original discovery path. Final regression verification must cover native categories as well as room buttons.

Final validation: 99 tests (including 413 replay episodes) passed; helper Debug, app Release clean, and CLI Release builds passed. Signed installation verified; five installed executable hashes match build products and all running owners restarted. Live native row selection and room AXPress returned success in final capture; a desktop Wallpaper menu click passed through unchanged. Green ring backing surface was visually inspected through CUA. User confirmation of final per-control actions is still pending.

Timing results below are observational samples from different live navigation sequences, not a controlled percentage speedup or pointer-to-photon latency. `direct_cycle_to_client_ms` measures resolver cycle start to snapshot acceptance, before compositor presentation. Pointer-window resolver timing excludes final evidence work.

```json
{
  "baseline": {
    "ChatGPT / direct_resolver_ms": {
      "n": 34,
      "median": 42.1,
      "p95": 146.26
    },
    "ChatGPT / direct_cycle_to_client_ms": {
      "n": 5,
      "median": 47.4,
      "p95": 55.6
    },
    "Brave Browser / direct_resolver_ms": {
      "n": 454,
      "median": 36.84,
      "p95": 185.91
    },
    "Brave Browser / direct_cycle_to_client_ms": {
      "n": 68,
      "median": 66.6,
      "p95": 265.2
    }
  },
  "final": {
    "Brave Browser / direct_resolver_ms": {
      "n": 116,
      "median": 17.43,
      "p95": 234.22
    },
    "Brave Browser / direct_cycle_to_client_ms": {
      "n": 27,
      "median": 35.0,
      "p95": 224.4
    },
    "ChatGPT / direct_resolver_ms": {
      "n": 28,
      "median": 10.12,
      "p95": 133.4
    },
    "ChatGPT / direct_cycle_to_client_ms": {
      "n": 4,
      "median": 10.4,
      "p95": 10.6
    },
    "MyHome / direct_resolver_ms": {
      "n": 55,
      "median": 34.5,
      "p95": 238.66
    },
    "MyHome / direct_cycle_to_client_ms": {
      "n": 25,
      "median": 39.8,
      "p95": 216.9
    },
    "OpenCode / direct_resolver_ms": {
      "n": 53,
      "median": 13.54,
      "p95": 250.35
    },
    "OpenCode / direct_cycle_to_client_ms": {
      "n": 12,
      "median": 79.65,
      "p95": 265.5
    },
    "Finder / direct_resolver_ms": {
      "n": 15,
      "median": 14.86,
      "p95": 250.5
    },
    "Finder / direct_cycle_to_client_ms": {
      "n": 7,
      "median": 17.0,
      "p95": 251.5
    },
    "System Settings / direct_resolver_ms": {
      "n": 6,
      "median": 19.25,
      "p95": 28.81
    },
    "System Settings / direct_cycle_to_client_ms": {
      "n": 4,
      "median": 22.95,
      "p95": 23.2
    },
    "ChatGPT / shortcut_resolver_ms": {
      "n": 25,
      "median": 9.45,
      "p95": 32.99
    },
    "Brave Browser / shortcut_resolver_ms": {
      "n": 93,
      "median": 15.94,
      "p95": 38.94
    },
    "OpenCode / shortcut_resolver_ms": {
      "n": 47,
      "median": 10.95,
      "p95": 68.64
    },
    "Finder / shortcut_resolver_ms": {
      "n": 14,
      "median": 14.8,
      "p95": 29.53
    },
    "System Settings / shortcut_resolver_ms": {
      "n": 6,
      "median": 19.25,
      "p95": 28.81
    }
  }
}
```
