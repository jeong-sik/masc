# Apple guest init command

The one-hour Keeper audit found successful guest boots followed by strict
command-mismatch refusals. An OCaml sandbox image supplies `opam exec --` as its
entrypoint, so passing `tail -f /dev/null` after the image did not create the
process declared by the boot plan. This repair is tracked in #46208.

The [retained observations](entrypoint-observations.json) contain two isolated
CLI runs, the six changed source/test file digests, and parse-only results.
The probe used container CLI 1.3.1 and the existing sandbox image, with unique
guest names, no network, and no Keeper volumes, identity or configuration mounts.
Both probe guests were stopped and deleted successfully.

| Invocation after common resource/name options | Observed init process | Matches plan |
| --- | --- | --- |
| `<image> tail -f /dev/null` | `opam exec -- tail -f /dev/null` | No |
| `--entrypoint tail <image> -f /dev/null` | `tail -f /dev/null` | Yes |

`apple_turn_start_argv` now pins the requested executable through `--entrypoint`
and places only its arguments after the image. The generic Apple boot builder
does the same; Nerdctl and Microsandbox keep their existing command grammar.
An absent or empty executable is rejected before boot. The v2 boot-plan identity
binds these explicit-command semantics, allowing existing image-composed guests
to enter the existing replacement path. Runtime identity, isolation, mounted
credential and shim checks remain in that path.

The CLI invocation was assembled by the isolated probe, not emitted by a newly
compiled MASC binary. Six changed `.ml`/`.mli` files passed OCaml 5.5.1 parsing;
this is not type-checking, execution of the MASC test suites, a full build, or
installed Keeper recovery. Existing protocol expectations were updated, and
the independent source review caught and corrected an additional Apple backend
expectation. No production guest replacement or server restart was performed.

The option semantics were checked against installed `container run --help` and
Apple's [1.3.1 process parser](https://github.com/apple/container/blob/1.3.1/Sources/Services/ContainerAPIService/Client/Parser.swift#L258-L295).
The current branch [command reference](https://github.com/apple/container/blob/main/docs/command-reference.md#container-run)
also documents the explicit entrypoint option.
