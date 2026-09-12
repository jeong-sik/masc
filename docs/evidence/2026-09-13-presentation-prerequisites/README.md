# Workspace presentation prerequisites

Presentation setup exposes the workspace parser and host renderer separately.
Reading the catalog probes the managed Python interpreter with `-I -B`, imports
`pptx`, verifies its managed environment and package location, opens the package's
empty presentation, and records its version. The renderer probe runs
`soffice --headless --version` in the current host environment.

The explicit parser action creates `<base>/.masc/runtime-tools/presentation` and
uses that environment's Python for `pip --isolated install --require-virtualenv
python-pptx`. The explicit renderer action uses an existing Homebrew installation
on macOS, or apt on Debian/Ubuntu. Other Linux distributions receive installation
instructions. Catalog inspection installs nothing.

```
masc prerequisite-actions presentation-tools --base-path WORKSPACE
masc prerequisite-actions presentation-tools --base-path WORKSPACE --execute presentation_renderer_install
masc prerequisite-actions presentation-tools --base-path WORKSPACE --execute presentation_parser_install
```

Setup forwards the selected workspace on both catalog and execution calls and
rejects readiness for another workspace. Each executed component is probed again.
A command exit of zero followed by a failed component probe returns a failed
receipt and nonzero exit. A working parser with a missing renderer remains
unavailable and identifies the missing component. `tools_available` requires both
probes to succeed. Readiness always reports `presentation_inspection: not_run`.

## Verification on 2026-09-13

- Python setup suite: 68 cases, 56 executed successfully, 12 skipped because a
  CI-built native executable was not supplied.
- Seven changed OCaml source/interface files passed parse-only checks.
- `git diff --check` passed.
- Independent adverse review found no remaining concrete P1/P2 after the selected
  component failure, pip isolation, and workspace identity corrections.
- Native CI targets: `test_sandbox_prerequisites,test_install_runtime_setup`.
  The latter includes actual native catalog and selected-action commands with isolated
  filesystem fixtures, an empty real Python venv import failure, and fake package
  managers that cannot install host packages.

No host dependency installation, local build, deployment, submitted PPTX parsing,
slide rendering, accessibility check, or end-to-end PPTX verification was performed
as part of this change. This is the dependency setup component for that later
inspection work.

## Primary references

- [Python virtual environments](https://docs.python.org/3/library/venv.html)
- [python-pptx installation](https://python-pptx.readthedocs.io/en/latest/user/install.html)
- [Homebrew LibreOffice cask](https://formulae.brew.sh/cask/libreoffice)

This branch depends on #35409 at
`e9a7609a718f17142a04395347199ab25d45ab49`; that remote base was verified before
publishing this stack. Its prior PR gate had successful native checks and an
unresolved lint failure. Those results are not evidence for this branch's native
behavior.
