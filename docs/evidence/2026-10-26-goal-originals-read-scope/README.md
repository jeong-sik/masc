# Original-eleven replay exposes unread subconditions

One isolated proof replay with the 8,143-byte `428e2d7f` prompt (source
`577e6e10a5eb10869796fc4f7f862f3ea3d7e17d`) approved the unchanged eleven-case
historical evidence packet. Independent semantic review **fails that proof**:
A3's judge-delivery observations and A7's lifecycle/external-acceptance
observations were available but not actually returned to the judge. This does
not establish failure of the underlying historical behaviors.

The 159 retained private originals bind 14 provider POSTs, 45 unique tools and
44 successful read replies. Two replies were empty EOF, so there were 42
nonempty pages, not 44 complete files. The A1 three-stage observations are
present in its returned partial page. Read [the coverage clarification](read-coverage-clarification.json)
with [the immutable result](result.json).

[Protocol review](protocol-review.json) and [response](protocol-response.json)
verify transport and persistence. [Sufficiency review](sufficiency-review.json)
and [response](sufficiency-response.json) retain the A3/A7 P2 findings. Actual
APPROVE, ACK, native reviewed/committed events and persisted
`proof_proven`/`awaiting_confirmation` remain unchanged.

The frozen executable is source `3e0d83d9d00fd2c133a8bb8cb33147f9479e07e6`,
SHA256 `00f3fdc897bea8874dc21bd9f471aef80ef9e2aebd4321b4483ce83508ef84e8`.
Only the prompt was applied through two normal isolated API overrides. All 76
input copies match the original packet. Fixture revision `d6f0451381b7f9076e956759253e0fae`
is distinct from primary revision `306708facbfb9379a9e51b8f7c815678`.

[Owned cleanup](owned-stop.json) retains the first post-TERM assertion failure
and later absence reconciliation. The transient assertion output was not
separately frozen; its cause is unknown. No signal was resent to the server.
Both owned PIDs were subsequently observed absent; descendants and fleet state
were not measured. Raw provider bodies and reasoning remain private, indexed by
[the metadata-only manifest](private-originals-manifest.json).

This rejudges retained historical evidence; it does not rerun eleven behaviors,
prove the primary Goal, install source577, measure general reliability or imply
human confirmation. A later prompt/control cohort cannot repair this old proof.
