# Browser Native Stack #45537: whole-stack restack

Scope: #45535 → #45536 → #45533 → #45548 → #45574 → #45602 → #45632,
with #45632 as the only whole-stack integration entry point. The unrelated
host-selection alternative #45565 is not included.

## Source integration

All seven layers were rebased with `gh stack rebase` onto main
`9b70cf4eac0e6fa93641e13048cec16e08c211b4`. The conflict resolutions preserve
both the incoming browser work and main's newer native target actions:

- Keep main's single `nativeTargetInput` helper for click, fill, hover and
  double-click. It catches URL read errors before and after selector discovery
  and refuses input on a changed page. The incoming URL re-read failure case
  remains in the OCaml peer regression. Its nine actual refusal/input calls
  replace the separate earlier seven/eight call expectations.
- Keep the cursor label on raw pointer/drag actions and snapshot-target clicks.
  The click label is passed through the shared helper; fill receives no label
  options. Keep the explicit observed identity requirement on Control calls.
- Keep download listing, file-input and file-chooser upload support together
  with main's hover/double-click capability entries. Preserve the distinction
  between snapshot targets inside frames and unsupported explicit `framePath`
  reads/inputs. Frame reads are rejected by the live transport gate before the
  peer; input refusals explain the supported snapshot route.

The range-diff retains all original commits and records the reviewed conflict
adaptations; it does not claim every patch stayed identical. A new focused
helper-test commit belongs to the cursor-label layer and is carried through
both upper layers in the same stack.

## Checks actually executed

- Parse all 44 changed ML/MLI files with `ocamlc -stop-after parsing`: passed.
- Parse all three changed TOML files with Python `tomllib`: passed.
- Check the seven self-citing changelog fragments: passed.
- `git diff --check`: passed.
- `node --test --test-reporter=tap test/test_browser_ego_target.cjs`: five tests
  passed. The test extracts the actual JavaScript helper from
  `lib/browser_ego_peer.ml` and executes it against a fake native page. It checks
  exact native action/argument dispatch after both URL reads, zero input on
  navigation or missing targets, no replay of uncertain input, and zero input
  when the second URL read fails. The existing test first exposed the changed
  click-label argument expectation (three passed, one failed); its explicit
  caller arguments/expectation were updated, including the VM realm crossing.

Raw successful TAP and whole-source/helper/test SHA256 identities are in
`docs/evidence/browser-native-restack-20261024/`.

## Evidence limits

These checks do not establish OCaml typing, linked peer/host behavior,
installation, a current-head live ego session or UI behavior. No local Dune
build or CI watch/poll occurred. Native executable verification awaits a usable
main build baseline and independent review of the changed integration scope.

The original author's actual same-origin/cross-origin iframe evidence belongs
to historical head `d3443448650294b27c7d33cb5268cb14d5785adc`. It is not
relabelled as execution of this restacked source. Current source review,
whole-stack approval, executable checks, installation and live browser proof
remain separate claims.

## Fixed main baseline for executable verification

After the first complete restack, the original main build repair #45675 merged.
All seven browser layers were rebased together again onto main
`c2dfa238ebd318a9152e70d874ac2cbf68ae2ad8`. This second whole-stack rebase had
no conflicts. The browser helper and its focused Node test source hashes stay
identical to the recorded helper receipt; that receipt names the first restack
baseline and is retained as that earlier source-boundary execution. Native
browser suites can now be requested against this repaired main dependency tree.
A new dispatch remains an execution request, not a passing test result.
