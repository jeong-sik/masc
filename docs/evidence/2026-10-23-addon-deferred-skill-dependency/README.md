# Deferred Addon worker Skill dependency repair

The actual selected check [39920131507](https://github.com/jeong-sik/masc/actions/runs/39920131507), head `bdccda5a872bcc3e5b6ac0c44d78c8b3bd4f5ec6`, failed while compiling `test_keeper_addon_deferred_runtime`. Its direct use of `Skill_source_config.parse_text` could not resolve the standalone module. The five selected suites were not executed; this is not a failed deferred-tool interaction assertion.

`test/dune` now declares `masc.skill_config` directly on that executable. `lib/skill_config/dune` provides `Skill_source_config` with `wrapped false`; `dune-project` disables implicit transitive dependencies. `masc_test_deps` already re-exports `masc.skill_snapshot`, which provides the next direct Skill call, `Skill_catalog_snapshot.configured`, but does not re-export `masc.skill_config`. No global dependency expansion or redundant snapshot dependency is needed.

The one-line repair changes no production interfaces, worker protocol, lifecycle behavior, fixture body or assertions. It is based on main `83660dc2c99552b8a8b704477f4a9adbd125738e`, which includes the earlier summary and five-fixture repairs. Historical failed runs remain failures of their exact heads.

Validation: `git diff --check` passed. No local Dune, type check, linking, OCaml tests, installed runtime or visible UI was exercised. Independent source review and any later selected execution have separate receipts; this repair alone does not establish A01, E01, G01 or H01 completion.

Independent adversarial source review: **PASS**, no P0–P2, frozen one-line source commit `6d6e8a570dcde89d260b85b04564119ea5ae11f1`; see the original review and JSON. This is source-only evidence, not a GitHub approval or an executed check.
