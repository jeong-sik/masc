# Bootstrap framed-readiness regression

The regression command uses the actual packaged native CLI with a synthetic
local SSH transport, rather than a real SSH host:

```sh
python3 test/test_exec_ssh_bootstrap.py \
  /tmp/mssh-candidate-runtime-f9bf6b4/masc-exec-ssh-bootstrap
```

Before the readiness repair, candidate source
`f9bf6b408afcff200131dfdd9040cba2551abab4`, helper SHA256
`ab41a3c7e5a3cba2a052e55312bc8f8c8ba45d3af1f0720d3cbbb77b6a43d410`,
ran 10 cases: eight passed and two failed. Both new cases received exit 0
and `SSH endpoint fixture provisioned.` despite an unusable framed transport:

- `test_same_major_config_refusal_is_not_success`: the same-major probe
  succeeds, while executing a frame refuses the configuration with unknown
  key `env_file`.
- `test_probe_success_without_framed_receipt_is_not_success`: the probe
  succeeds, while framed execution returns no protocol trailer.

The positive cases still require workspace preparation, repeated preservation,
and endpoint environment retention. The focused OCaml preflight case additionally
distinguishes transport/shim refusal from an executed check's nonzero result.
These new assertions have not yet passed on a rebuilt helper. Parsing the changed
sources is not compilation or runtime proof. The real SSH stale-shim failure and
its separate provisioning receipt remain documented in the neighboring README.

The first rebuilt-candidate requests at source
`d222bd836c1fe09e84f485286f20d17332ee610d` failed to compile the bootstrap
executable with `Unbound module Eio` at `Fs_compat.set_fs (Eio.Stdenv.fs env)`:
targeted run 40195161883 and macOS artifact run 40195163878. The helper declared
`eio_main` but omitted its direct `eio` dependency; the repair adds that explicit
library. Those failed runs do not prove that the new CLI assertions pass.

The macOS retry 40196633648 at source
`cf52e413dc6305df7989630c56b2671d3815ec12` then reported
`Unbound module Process_eio` at its initialization call. The helper also needs
the direct `masc.masc_process` library, whose unwrapped module is not exposed by
`open Masc`. This dependency is now explicit as well. The preflight library's
12-case suite passed in the first targeted run; that does not compile this
separate executable or prove the CLI regressions pass.

Candidate `327fd90f7fec1a07f4ca7e5836d5cad3e8e39c15` compiled and packaged
successfully in macOS run 40198143147. Linux CLI run 40198292667 executed all ten
cases: nine passed; the config-refusal assertion failed because Cmdliner wrapped
`unknown key "env_file"` across lines. The actual result was the required nonzero
`remote_ssh_preflight_unavailable` refusal with the original config error intact.
The assertion now normalizes diagnostic whitespace before checking that cause;
it still requires nonzero exit, no success text, no false root-missing claim,
and no Keeper workspace creation.

The packaged macOS helper from run 40198143147 was then executed locally after
its artifact checksums and the main executable's source identity were verified.
The same ten CLI cases exposed a native runtime failure: seven failed with
`waitpid(): Interrupted system call`, including normal preparation and symlink
refusal. This is separate from the Linux line-wrapping assertion. Synchronous
interactive subprocess waits inside the new Eio runtime now resume `EINTR` on
the same owned PID; streaming writes likewise resume only the interrupted write
at its current offset. Commands and complete uploads are never replayed as a
retry. Actual post-repair native execution is still required.
