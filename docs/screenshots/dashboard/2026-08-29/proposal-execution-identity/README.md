# Dashboard proposal execution identity

These frames render the real `KeeperToolCallInspector` from merged source head
`445dab4db08b84be24b3f7d6e58ac3b8d85d8a70` in Chromium. A loopback Vite
server delivered the module and Playwright supplied one deterministic
`tool_call_io` response through `window.fetch`.

| State | Interaction | Screenshot |
|---|---|---|
| Collapsed | Wait for `proposal-execution-badge` | [PNG](01-collapsed.png) |
| Expanded | Click the row toggle and wait for all three full identity fields | [PNG](02-expanded.png) |

The fixture uses `exact-assembler-run-42`, a 64-character proposal id, and
`retained_match`. The expanded frame proves that the full identity is visible;
the collapsed frame proves the compact badge. No screenshot text was replaced
or edited after capture.
