# Catalog publication authority

Issue [#27898](https://github.com/jeong-sik/masc/issues/27898) requires one
immutable provider/model selection and removal of reverse inference. This
investigation starts at `168e1e2b18aed0ca55dcd121ea565aeca9da89b2`.

## Current boundary

`Provider_declarations.capture` reads `Model_catalog.global` and
`Provider_catalog.global` separately. Each source has its own mutable atomic
override. The one-binding and batch construction repairs retain the admitted
selection after capture; they do not publish both sources as one transaction.

The [OCaml 5.5 Atomic contract](https://ocaml.org/manual/5.5/api/Atomic.html)
defines operations on one atomic reference. The
[parallelism manual](https://ocaml.org/manual/5.5/parallelism.html) permits
sharing immutable values between domains and describes atomic synchronization.
From these contracts, a single immutable publication value can carry all
catalog facts through one read. Separate source writes remain separate
operations. This is a design inference; a concurrent mixed-publication failure
has not been executed in this investigation.

## Remove the dependency cycle first

The JSON provider parser used `Capabilities` for records and presets and
`Provider_config` for the wire type and default request path. Both modules also
depend on model policy. A snapshot module cannot own both decoded catalogs if
those lower parser dependencies lead back to its policy consumers.

`Capability_profile` now owns the immutable records, vocabulary projections and
provider presets. `Capabilities` re-exports their types and values while keeping
model lookup, selected request-policy projection and response observations.
`Provider_kind` owns the closed wire's default request path; config, catalog and
runtime construction read that same mapping. The previous config path helper
is removed and all callers use the wire module.

The extracted types/defaults/projection and sampling alias retain their source
bytes. The preset block keeps its expressions and inline controls; its comments
are updated for the new module's purpose and a stale variant count is corrected.
The two fresh nominal types are explicitly re-exported with equality, preserving
record/constructor identity for parser and policy callers. No profile has a model
lookup, credential read, mutable catalog or execution config dependency. Parsing
behavior and policy values are unchanged. Dependency-source analysis is not a
build or typecheck result.

The two derived `show_`/`pp_` debug printers move with their type definitions.
The installed `ppx_deriving.show` defaults to `with_path=true`, so their
module-qualified diagnostic prefixes follow `Capability_profile` rather than
`Capabilities`. This is a diagnostic-output change, separate from policy values,
parsing and type equality; it is not a claim of identical behavior for every
public observation. No repository consumer of those exact printer strings was
found during source review. The prefix behavior is established by inspecting the
deriver, not a new execution of its output.

## Required next change

Create and admit the whole immutable selection before publication. One authority
must own the active snapshot, including exact model rows and provider declarations.
Readers must obtain one value; publishers must supply both sources together and
handle typed admission failure before replacing the current snapshot. Remove the
independent source setters and migrate their callers; a second cache, retry loop
or compatibility adapter would preserve the split authority.

Verify failed admission retains the previous selection, coherent replacement
changes all facts together, captured selections survive replacement, and the
existing custom/native/batch behavior remains valid. The original issue also
requires strict parsing, explicit high-level provider/model selection, account
binding and removal of remaining reverse inference. This structural dependency
change alone does not satisfy those acceptance criteria.
