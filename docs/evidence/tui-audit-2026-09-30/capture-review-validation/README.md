# Capture tooling validation

This is an installed-binary capture in an isolated temporary workspace with synthetic HTTP fixtures. It is not a build of PR #40124 and not production evidence.

- Binary commit: `ff7f49c40cd09e36acd18e76df0c0c512f6a7eab`.
- Binary SHA256: `0ba80256daabb703cdcfbed4097a31b0c5a2cb136a424d59015da1d919951f44`.
- The revised script completed 24 text/PNG pairs at measured 80x41,120x41,242x41. Every one of the48 artifact hashes was independently checked after capture. Board list/detail text differs at all three widths; the80-column detail reached its Comments body.
- Manifest input hashes bind the exact capture script, fixture helper and terminal helper. The fixture payload hash is before temporary workspace identity injection; seed/identity logic is bound by the fixture helper hash. These inputs differ from historical baselines and do not establish an old/new renderer comparison.
- Negative checks ran under Python optimization: a missing executable invalidated a preexisting complete manifest, mutated input was rejected, and a wrapper with an unrelated binary was rejected.
- Earlier trials correctly stayed incomplete: the installed Dashboard no longer rendered Goal rows; the initial Goal title folded at80columns; then Board rejected a missing `comment_page`. Ready markers and the fixture were corrected before this final complete run.
- This confirms capture mechanics for these surfaces and this installed binary. It does not prove full screen/state coverage, Release CI, installation of a proposed renderer, or production behavior.
