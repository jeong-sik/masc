# Recover one retained Librarian child

The history-resolution worker previously wrote a successor body before the
resolution recorded its identity. A stop between those writes left a body
that the next pass could not discover, so that pass could render another
request with another ID, Memory basis, template or clock.

`Child_prepared` now retains the complete request and its ID and digest in the
existing resolution envelope before the body is written. Recovery stages those
same bytes and strictly reads the canonical body back before compacting the
envelope to `Child_intended`. Only that compact intent can authorize retaining
the child owner; `Child_prepared` grants no provider, Memory or source effect.
An existing identical body is read without replacement. Different or
unreadable bytes at its content address are preserved and refused.

The public projection exposes the prepared child's ID and digest only. The
private request remains in the stored preparation until compaction; it does not
enter the HTTP response. The existing strict deployment preflight decodes this
intermediate phase from the same resolution namespace.

This unit also closes a lower-level authority gap in the preceding Cut fence
unit. The queue worker rejected a Cut successor, but the public Intent APIs
and the Lineage checks used by direct host authorization did not distinguish
Cut fences. A shared State check now rejects that authority at both producer
and consumer boundaries. A retained Cut fence remains an effect denial, with
no successor permission in this unit.

Five new fixture cases cover the direct Cut intent/Lineage/host boundary,
preparation before a body, body before compaction, compact intent before child
ownership, and conflicting body evidence. The preparation cases also change
Memory and the current prompt before recovery, check the same ID and bytes,
deny a competing preparation, inspect the private/public projection, and check
that no provider call or source ACK occurred. These cases model the retained
states at write boundaries; they do not claim a real process-kill experiment.

At authoring, parsing and whitespace checks passed. OCaml typing and these
behavior cases have not run. Source review, stack publication, integration,
deployment and recovery of the live original requests remain separate work.
