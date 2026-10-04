# Lane composer follow-ups

## P3 browser scenario improvements

- Exercise horizontal and vertical scroll gestures inside the graph canvas and
  capture its final agent layer. Current Chromium proof establishes no document
  overflow at 390px; it does not establish inner scrolling interaction.
- Download every declaration in the browser scenario. Current proof renders and
  parses all four TOMLs, and verifies the actual download of the first one.

Group these browser-scenario improvements in a later stack. They do not block
the reviewed composition/export source.

## P3 Docker qualifier portability

- Pin a consistent explicit Docker context and client environment for control
  commands and stdio transport. The current successful run used desktop-linux;
  cross-context host environment overrides remain a portability follow-up.
- Inspect `MemorySwap` as well before reporting the derived swap limit. The
  current resource proof checks manifest CPU, memory and PID settings.

## Execution qualification still required

Browser proof covers the standalone HTML and synthetic input settings. The
explicit Docker package qualifier additionally proves separate package images,
isolation settings, stdio computation/reporting and fixture model evidence
propagation. Its native-shaped port metadata and model answers remain fixtures.
Native TUI rendering, installation through real reconciliation, integration
with the native Docker worker factory, real providers and report use by a Keeper
remain separate, unproven stages. Carry them
into the applicable Core/release qualification under the current MASC workflow;
do not report source APPROVE or local browser PASS as those results.
