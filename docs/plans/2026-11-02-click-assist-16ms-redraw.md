# 16 ms ring redraw

Change the overlay's pointer-resampling timer from 33 ms to 16 ms. Snapshot-triggered rendering remains immediate. Discovery, target admission, evidence expiry, click delivery, menu-bar handling and movement-trigger scheduling remain unchanged.

A bounded five-second diagnostic aggregates actual main-thread timer intervals and render-call work durations. It allocates no per-tick sample arrays. OVERLAY_REDRAW_STATS reports mean/max delivery interval and mean/max render work. These are callback/work measurements, not compositor presentation or pointer-to-photon measurements; render(snapshot) may coalesce drawing when nothing changes.

Validation: run semantic regression suite and required helper Debug, app Release clean, CLI Release builds. Verify installed binaries/signature. Observe timer measurements during real pointer movement and confirm actual rings/clicks across Brave tabs/close, OpenCode tabs, YouTube seek/drag normal/full-screen, MyHome categories/rooms, desktop menus and BetterDisplay. Do not commit automatically.

Validation completed: 100 tests and all three builds passed; installed signature and five executable hashes verified, helper/agent restarted. User confirmed “All worked correctly” for every requested ring/click case. The renderer inspection while the pointer had left the targets showed a blank surface; visible target rings were verified by the user. No automatic commit.

Measured callback/work results (not display presentation):
```json
{
  "samples": 5007,
  "mean_interval_ms": 16.006203315358498,
  "max_interval_ms": 36.61,
  "mean_render_work_ms": 0.07320351507888954,
  "max_render_work_ms": 3.559
}
```
