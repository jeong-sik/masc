# Shell IR Oracle Sidecar

Non-production fixture emitter for Shell IR parser hardening.

This sidecar parses a shell command with `mvdan.cc/sh/v3/syntax` and emits the
data-only JSON contract consumed by `lib/exec/shell_ir_oracle.ml`.

It does not execute commands, make policy decisions, or participate in runtime
authorization. OCaml remains the owner of descriptor parity, risk floors,
receipts, and enforcement.

## Usage

```sh
go run . --pretty --command 'echo hello > out.txt'
printf 'cat file.txt | wc -l\n' | go run . --pretty
```

Parse errors still emit a JSON fact with `parse_status: "parse_error"` and
`commands: []`, so OCaml callers can fail closed without scraping stderr.

## Contract

- `schema_version`: `1`
- `parser`: `mvdan.cc/sh/v3/syntax@v3.10.0`
- JSON shape: `Shell_ir_oracle.t`
- Intended destination: `lib/exec/test/fixtures/shell_ir_oracle/*.json`

The dependency version was selected from `go list -m -versions mvdan.cc/sh/v3`
on 2026-06-04 KST. `v3.10.0` is the newest checked release whose module
declares compatibility with the repository CI Go version (`go 1.22`).
