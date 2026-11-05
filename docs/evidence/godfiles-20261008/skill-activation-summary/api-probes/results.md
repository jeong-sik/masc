# Public API compiler probes

Using built CMIs, including the internal byte directory:

`opam exec -- ocamlc -I _build/default/lib/.masc.objs/byte -I /Users/dancer/.opam/5.5.1/lib/yojson -c -o <isolated-temp>/<case>.cmo api-probes/<case>.ml`

| Case | Terminal exit | Actual diagnostic |
| --- | --- | --- |
| `public_read` | 0 | Normal public ledger summary call compiles |
| `private_activation` | 2 | Cannot create values of the private type `L.activation` |
| `private_task_ids` | 2 | Cannot create values of the private type `L.task_id_set.Task_ids` |
| `private_revision` | 2 | String constant supplied where `L.ledger_revision` is required |

Sources are adjacent. These checks prove the stated public private boundaries,
not installed-library private namespace exclusion. Artifacts are emitted to
separate `mktemp` directories rather than the source tree.
