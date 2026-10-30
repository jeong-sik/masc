# Keeper schedule target typing

The schedule reply target match in main `6505bd4f` used a wildcard over
`surface` and its nested `keeper_mode`. OCaml warning 4 is fatal for this
project. The repair reuses the existing exhaustive `view_is_chat` binding;
chat replies still target `msg_target_keeper_name`, and all other surfaces
still use the selected Keeper.

## Reproduce the reported diagnostics

Requires Python 3 and OCaml 5.5.1 with compiler-libs. From a checkout containing
the two commits, run:

```sh
python3 docs/evidence/2026-10-25-tui-schedule-target-typing/run_scope.py \
  --before-ref 6505bd4fedb7e78121fda9a2195ced0a03f2c629 \
  --after-ref 84bea1cd3257fa7e94411586348dffd86728e0d8 \
  --receipt /tmp/tui-target-typing-new.json
```

The receipt path must be new. `--repo PATH` selects another checkout;
otherwise Git resolves the repository from the current working directory.
Compilation products and extracted source exist only in an owned temporary
directory, removed on exit. No dependency installation or Dune is invoked.

`extract_scope.ml` reads the actual source AST, retaining the complete
`keeper_mode`/`surface` declarations, `view_is_chat` binding and the unique
target expression inside `apply_keeper_schedules_read`. Two minimal records
provide the referenced field types. The selected-Keeper predicate is a
function parameter, rather than a replacement implementation.

The exact selected fragment is checked with:

```sh
ocamlc -w +4+8 -warn-error +4+8 -stop-after typing before_scope.ml
ocamlc -w +4+8 -warn-error +4+8 -stop-after typing after_scope.ml
```

The recorded invocation in `typing-receipt.json` used after-ref
`ed1f4b12ea1ceff9d644b8aee8991aa307072934`: before exited 2 with both reported
warning 4 errors, and after exited 0 with empty diagnostics. The subsequent
lower head `84bea1cd` adds only its changelog fragment; `source-identity.json`
confirms the complete TUI source bytes equal the executed input. The command
above reproduces the same source under that published lower head.

## Evidence boundary

This is a compiler/type/warning fragment check. It does not typecheck or
build the complete TUI module or executable, execute state mutations, or
validate the installed UI. Existing `test_tui_loading_notice` source assertions
cover stale request generations, late other-Keeper replies, and chat target
ownership while another Keeper is selected; that existing suite was not run.
No full project build, Dune, CI, installation or runtime proof is claimed.
