# Final candidate installation acceptance

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
The upgrade regression suite uses fixture executables; it is separate from the
actual-artifact first-install checks. The release evidence bundle's lifecycle
suites are source tests, not a count of installed user turns.

No tag publication or live workspace deployment is part of this acceptance pass.
