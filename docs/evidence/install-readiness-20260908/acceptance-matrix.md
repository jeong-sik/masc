# 0.34.0 installation acceptance

## Frozen feature candidate

Production source `215517f229` includes the reviewed #34298 scene feature and
test dependency repair, as well as the installation/Kata fixes. Further feature
work belongs to a subsequent release; acceptance corrections remain possible.
[Freeze PR #34303](https://github.com/jeong-sik/masc/pull/34303) tracks integration.
The four-platform [Release run 34192837971](https://github.com/jeong-sik/masc/actions/runs/34192837971)
and [browser/Keeper regression run 34192899797](https://github.com/jeong-sik/masc/actions/runs/34192899797)
cover this source. The browser/Keeper regression run passed. All four native installation/reinstall jobs passed: Linux x64, Linux ARM64,
macOS ARM and macOS Intel.
[Installed Kata run 34194081312](https://github.com/jeong-sik/masc/actions/runs/34194081312)
also passed. [Frozen candidate evidence](frozen-215517f229/README.md) binds
the actual binary, guest storage and TUI behavior to this source. Public tag
publication and live deployment are separate steps.

## Earlier installation baseline

Candidate source: `f92979e06b146ff0c206f2594fe3cc2519d88416`.
[Release build](https://github.com/jeong-sik/masc/actions/runs/34191784974) and
[Keeper regression suites](https://github.com/jeong-sik/masc/actions/runs/34191815788)
are the verification runs for this candidate. The four targeted Keeper suites
passed: microVM backend, Kata inventory, turn-up arguments and recovery transmission.
Platform and installed Kata outcomes are separate acceptance results.

| Platform | Required installation evidence |
| --- | --- |
| Linux x64 | Installed executables, config and Skills; server/dashboard; installed Docker tool turn; fresh Ubuntu runtime-library-only installation |
| Linux ARM64 | Same checks on the native ARM64 runner |
| macOS Apple Silicon | Installed executables, config and Skills; server/dashboard on the native Homebrew-equipped runner |
| macOS Intel | Same checks on the native Intel Homebrew-equipped runner |

The macOS jobs do not establish a clean Mac VM installation and do not install
the Linux guest shim from their platform-only artifact. The complete release
distributes Linux shim assets separately. The Linux container check installs
documented runtime libraries without OCaml or a source checkout.

Installed Kata acceptance must additionally bind the successful Linux x64
artifact to its embedded source commit, build/import the embedded general image,
create a Keeper through the CLI, execute a real guest tool, verify its canonical
checkpoint, and reread the same volume bytes after guest recreation. Ordinary
Kata volume smoke alone does not satisfy this requirement.

First-turn model responses are scripted loopback fixtures. They establish tool
wiring and persistence, not model quality or sustained autonomous operation.
The three standalone upgrade regression cases use fixture executables. The
extended install smoke also tests actual-artifact same-version force reinstall:
it preserves exact runtime/Skill/operator bytes and a deliberately removed optional
theme. This passed locally against the `f92979e06b` macOS ARM artifact before the
scene feature was included. It does not test older-schema migration.
The release evidence bundle's lifecycle
suites are source tests, not a count of installed user turns.

No tag publication or live workspace deployment is part of this acceptance pass.
