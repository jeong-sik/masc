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
