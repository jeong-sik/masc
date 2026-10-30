# PR40965 review response: summary priority and declared PTY dependencies

Response to 4177217921, 4177217923 and 4177217926, based on published
`9edfd3f9727e467d05327457a67f428ff642f8c3`.

The original 40×16 repair was actually exercised later than the historical
2026-10-03 capture: `prior-40x16-pty.txt` retains that color/no-color run and its
binary SHA256 `ef23f44392aa4167e899fcee8474f02dfc8beb830eaf1cbd7e421b2a79ed055d`.
Its recorded `work-minimum-*` frames include selected Goal navigation and footer.
This log is separate from the old browser/snapshot manifest, which is unchanged.
It does not independently establish a complete exact-source build receipt.

## New behavior repair

The reported small-count 44×17 example did not reproduce on the retained binary.
A distinct valid case did: at 44×19 with longer integer counters (all exactly
representable and below 2^53), the backlog did not fit but the shorter optional
net-change block appeared. `priority-red.txt` captures that actual failure before
the renderer changed. The new test retains the original small-count and retained
history scenarios; it does not replace or weaken their assertions.

The renderer now remembers whether the current backlog was admitted before
adding the optional trend. Existing physical-row reservations remain. The alias
now declares `tui_keyboard_chat.py` and its observer/tools imports.

## Execution and limits

- Warm focused `scripts/dune-local.sh build bin/masc_tui.exe`: exit 0.
- Ruff on the changed fixture: passed; Pyright: zero errors/warnings.
- `scripts/dune-local.sh build --sandbox=copy @test/runtest-test_tui_surface_studio_pty`:
  **exit 1 before PTY execution**. Switching sandbox mode rebuilt dependencies;
  unchanged consumers could not resolve two public aliases to private Agent Core
  modules. Full log preserved in `sandbox-alias-failed.txt`, tracked as
  [#41188](https://github.com/jeong-sik/masc/issues/41188). A cold parent baseline
  was not executed; pre-existing attribution is source identity only. The warm
  build does not clear this complete native dependency failure.
- A temporary directory then received only the seven Python files declared by
  the alias and a copy of the retained warm-built executable. `PYTHONPATH` was
  removed. Running the actual fixture from that directory passed: six priority
  frames (44/45/46×19, color/no-color), plus all prior surface journeys and 40
  captures, including selected Goal row/identity/footer at 40×16. This establishes
  Python import closure and fixture behavior, not the failed Dune build closure.

The executed retained binary SHA256 is
`4b55b1b6f6281ca9a0264eedc9341740cbc9e531709143970479ac2fb46e9841`.
`manifest.json` binds the current response source, executable and exact logs.
No source was changed during either build or fixture execution. No new browser,
provider, installed runtime, full suite or hosted CI result is claimed.
