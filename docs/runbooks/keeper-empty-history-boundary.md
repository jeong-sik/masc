# Accepted empty history after Codex overflow

A request may omit every conversation atom while retaining its current goal and
pinned context. That is a measured empty range, distinct from missing input
observation. A successful response records the boundary after the offered
history, witnessed by its last atom's opening-message digest. Later requests
retain this boundary while the witness matches, and can carry newly appended
atoms. No checkpoint or Librarian state is deleted or rewritten.

TurnRecord now writes `model_input_front` as an exact tagged object:
`at_atom` and `after_history` carry `digest`; `empty_history` carries no digest.
The surrounding atom counts must agree with the variant. This replaces the
`front_atom_digest` wire field in both the attempted range and the
response-observed range. The OCaml and dashboard readers use this same schema.

An Agent Core floor response can also use `empty_history` with a positive
`total_atoms` count and zero `transmitted_atoms`. That observation carries no
history witness: it stops the seed scan from reusing an older response, but
cannot seed a position in a nonempty history. A witnessed `after_history`
boundary remains distinct and can preserve its position on a later fresh Start.
Codex Resume sends no history and records no new model-input window.

This is an intentional internal schema break, rolled out on fresh
TurnRecord state. Rows written with `front_atom_digest` are not read: there is
no reader, compat decoder or migration for that field. The strict decoder
counts each such row as unreadable, row by row, so the store is not rejected as
a whole and an old row never proves a current boundary.

## Fresh-state procedure

1. Stop the MASC server so no Keeper writes TurnRecords during the cut.
2. Move each `<base-path>/.masc/keepers/<name>/turn-records/` directory out of
   `<base-path>/.masc`, or delete it. Nothing reads the moved files.
3. Leave the canonical checkpoint, the turn-boundary store and the Librarian
   state (continuity snapshot, read position) in place. The carried-range seed falls back
   to the Librarian point or the last completed turn boundary until the first
   response-observed TurnRecord is written.
4. Deploy the producer and both readers (OCaml and dashboard) together and
   start the server.
5. Evidence: after one Keeper turn, `<base-path>/.masc/keepers/<name>/turn-records/`
   holds only rows with `model_input_front`
   (`rg -c front_atom_digest <base-path>/.masc/keepers/*/turn-records` finds
   none), the server log has no `seed read skipped unreadable turn records` line, and the dashboard
   turn-record panel decodes the new rows.
