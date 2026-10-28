# TUI surface inventory and compact viewport audit

The operator asked for an inventory of the entire TUI before prioritising the
screens with the highest information complexity. This is a source inventory,
not a claim that every state or action has been exercised.

## Scope and observation

- Source: `bin/masc_tui_types.ml` (`surface`, `surface_ring`, `keeper_mode`,
  `keeper_detail_tabs`, `config_panes`, `tools_pane`, `lanes_mode`,
  `runtime_mode` and `usage_section`), `bin/masc_tui_render.ml` and the
  command-palette and key tables at source commit
  `ce29779050f54bc8a6d1bafd0b67d03230a1f344`.
- All 23 `surface` constructors were opened by read-only navigation at
  140×36 and 80×24. The seven Config panes were opened separately. These
  observations used the installed TUI and live server at commit
  `3f5585167eee5315430009d0adc8c075ae91aefc`, not a binary built from the
  inventory source. There was no diff in `bin/masc_tui*` between those source
  commits; that does not establish dependency or runtime parity. Loading,
  empty, failed and detailed states were not all covered.
- Local, unsanitized terminal output and the navigation log are under
  `artifacts/tui-surface-audit-20261028/`; they are not part of this document
  or a public proof bundle. Only aggregate findings are reported here.

## Seven navigation destinations and their surfaces

| Destination | `surface` constructors and principal nested readings |
| --- | --- |
| Dashboard | `Overview`: decisions and continuation. |
| Work | `Planning`: Goals and Tasks, list and detail; `Approvals`: approvals, questions and answer/detail; `Verification`: Task Review; `Harness`: Task Verdicts; `Fusion`: list, run and launch form. |
| Keepers | `Keepers`: list, detail, logs, calls, chat and runtime picker; `Schedules`: list and selected schedule; `Memory`: fleet, selected/fleet facts and fact detail; `Changes`: keeper changes and diff. Keeper detail has Info, Items, Sandbox, Settings, Secrets, GitHub, Identity, Channels, Automation and Runs tabs. |
| Usage | `Metrics`: Plan, Trend and Keepers usage, plus Engine & Scheduler, Work & Outcomes, and Memory & Gate Safety telemetry. |
| Board | `Board`: list, read and compose. |
| Workspace | `Repositories`: repository list and workspace activity; `Code`: tree, file, diff, notes and history; repository-change overlays are also reachable from other views. |
| System | `Config`: runtime.toml, models, params, prompts, presets, themes and voice; `Runtime`: candidate orders, all runtimes, selected candidate and route/status detail; `Lanes`: feature overview, run list/detail, measurement and inventory detail; `Clients`: list and detail; `Resources`; `Tools`: surface, async, activations, usage and catalog; `Acting`: activity; `System_logs`: list and detail; `Connectors`: transport list and Browser Lane. |

Palette entries and overlays also expose Collab/play, MSX/DOS observation,
plugin inspection, account login, agenda, help, search, inspectors and action
confirmations. Those are separate interaction states, not additional `surface`
constructors. Their mutation paths and every nested state were not exercised by
this inventory.

## Initial prioritisation

In the live 80×24 observations, Runtime's candidate table showed 1 of 23 rows
under a six-line authority block; Memory showed 1 of 43 keepers while selected
context and folded fleet summary occupied the page; Work showed 2 of 27 goals
below wrapped counts and snapshot history. These are observations for that
workspace and instant, not universal performance or usability measurements.
They justify examining those three renderers and their scroll ownership first.

Features showed five of its 30 rendered rows with a selected detail below it;
its title and observation-window qualification remained visible. Usage, Board,
Workspace, Schedules, Tools and other surfaces need follow-up for language,
selected-detail navigation and empty/error states even where no first-screen
row count established a comparable problem. Existing changes to the System
preset and settings pages are tracked separately in PR #46604.

## Design references

The repository's [layout language](../design/tui/LAYOUT-LANGUAGE.md) requires
one owner per fact, visible failures and matching render/scroll geometry. The
current [lazygit key reference](https://github.com/jesseduffield/lazygit/blob/master/docs/keybindings/Keybindings_en.md)
provides a relevant example of keeping list navigation and the active view's
controls explicit; it is a reference, not evidence that MASC already behaves
that way.
