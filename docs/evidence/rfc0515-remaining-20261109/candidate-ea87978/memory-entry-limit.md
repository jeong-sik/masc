# Keepers shortcut skips the initial memory-health read

Frozen executable/source: `ea87978b18e3fc6c4a143cf8e74de8cbc495d67e`.

Observed boundary: the private paired TUI entered Keepers without issuing a memory-health GET. The capture agent's short diagnostic then pressed `R`; the proxy immediately recorded `GET /api/v1/dashboard/keeper-memory-health` with HTTP200, and Memory subsequently showed three followed rows. This observation was reported by the capture agent through root. It establishes that explicit refresh reaches the native memory loader; it does not establish the original shortcut loaded on entry.

Source chain:
1. `bin/masc_tui_keys.ml:327` defines the shared Keepers jump; `:1977` matches it through `opens_keepers`.
2. `bin/masc_tui.ml:39364` handles that shared shortcut using only `transition_keeper_view state (Keepers Keeper_list)`.
3. `bin/masc_tui_types.ml:12896` implements that transition by changing view, closing Story, and carrying selection. It does not owe or launch memory health.
4. `bin/masc_tui_types.ml:20522` initializes memory-health demand as `Settled`, with no snapshot and no owed row.
5. `bin/masc_tui.ml:9574` reconciles visible memory-health demand. Its `Settled,None,[]` case at `:9594` does nothing, so visibility alone does not recover a missing arrival demand.
6. The normal surface-navigation path calls `launch_surface_reads` at `bin/masc_tui.ml:8777`. Its Keepers-list branch at `:8602` owes and launches memory health. The shared shortcut bypasses that path.
7. Explicit `R` invokes `launch_memory_health_load` for Keepers at `bin/masc_tui.ml:40027`. That loader at `:6611` admits the workspace request, then calls `Loader.load_memory_health`; `bin/masc_tui_loader.ml:1557` fetches the direct GET.
8. World has its own visibility-driven `Memory_world.start` path at `bin/masc_tui.ml:9607`, explaining why World inventory can arrive while initial memory health remains unrequested.

Cancellation/admission limits: the memory launcher checks authority and in-flight state, and workspace recovery can issue normal arrival reads. Those paths mean startup timing can change the symptom; it is unnecessary to infer a stuck cancellation or blocked POST as the cause of this observed shortcut route. The successful `R` diagnostic rules out an inability of this candidate/private server pair to perform the direct memory-health GET.

Capture workaround: wait for server/workspace readiness, enter Keepers, press `R`, and retain the resulting memory-health GET and populated native rows before taking the requested frames. Apply this independently for each terminal-size process. Record the refresh action in the capture manifest.

This is an inherited navigation-boundary finding, separate from the five requested display layers. No product source fix was made or proposed for the capture. No CI run was dispatched. These source pointers and the capture-agent report do not constitute a new UI regression test.
