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

This is an intentional internal schema break. Publish producer and readers
together and use fresh TurnRecord evidence for verification. Older rows are
rejected by the strict decoder and reported as unreadable; they do not prove a
current boundary. There is no migration or automatic deletion of live state.
A rollout must explicitly decide how to retain the older observation archive;
the canonical checkpoint history remains independent of that archive.
