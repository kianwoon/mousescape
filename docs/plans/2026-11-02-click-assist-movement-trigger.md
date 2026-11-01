# Coalesced pointer movement refresh

Goal: reduce the wait for the next 50 ms polling tick when the pointer starts moving. Keep discovery, nearest-target selection, evidence expiry, ring drawing, native menu handling and click delivery unchanged.

The agent observes mouseMoved passively on its main loop. A dispatch data source merges events on the client queue; hints are sent at most once per 50 ms through the existing XPC connection. Hints carry no target or click authorization. Circuit-open/stopped clients send nothing. The resolver merges hints, keeps at most one delayed refresh, reads the current pointer and skips hints already serviced by its timer. After an event-driven refresh it restarts the regular 50 ms timer, preventing an immediately redundant timer beat. Timer polling remains available if monitoring/transport fails. Drag and button events are not observed by this listener.

A first attempt placed the NSEvent monitor in the XPC service. Live pointer generations advanced but no movement-trigger records appeared; this was detected before declaring success. The listener was moved into the AppKit agent.

Measurement: RESOLVER_MOVEMENT_TRIGGER wait_ms measures resolver scheduling delay from receipt/handling of a coalesced hint to its refresh, excluding input delivery and IPC. CB_TRACE remains the existing cycle-to-client metric, not pointer-to-photon latency. Live validation pending on corrected installed build.

Corrected build: all three required builds and 99 semantic regression tests passed. Installed app passed strict/deep signature verification. The agent listener is proven active by live RESOLVER_MOVEMENT_TRIGGER records. Initial 70-trigger sample: scheduling wait median 0.01 ms, p95 261.09 ms, 39 under 5 ms. This measures only the scheduling stage after the hint handler begins; it excludes delivery/IPC/earlier queue backlog and is not a claim of total ring latency. Slow active accessibility walks remain a source of delay. Final user control-by-control click check is pending.

Final user verification: user reported “All worked correctly” for rings and single clicks across Brave tabs/close, OpenCode tabs, YouTube normal/full-screen seeking and dragging, MyHome categories/rooms and desktop menus. Final live capture included 89 movement-triggered refreshes at the sampled checkpoint (median scheduling wait 0.01 ms). No total pointer-to-visible-ring speedup percentage is claimed.
