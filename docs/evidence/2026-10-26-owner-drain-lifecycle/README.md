# Production owner-local HITL drain lifecycle

Relates to #25860 and its consolidated member #25166. Source base:
`4ecf1de7a6a324bf9e55818c496768053f5edc4e`.

The added control runs two real `resume_persisted_auto_judges` fibers from a
shared Promise barrier against four persisted approvals, two per owner, with
one worker slot per owner. It uses the real Worker, AGENT_CORE exact-output
flow, local HTTP server, queue persistence and production completion callback.
It does not inject a worker or callback, or manually claim/release entries.

The HTTP server holds the first two responses independently. Both initial
workers must dispatch while their successors remain unbound, and the two
recovery reports must admit exactly the two first approvals without failures.
A further sweep cannot admit duplicates. Releasing only one HTTP response must
complete that owner's first approval, release its live claim and dispatch its
successor. The other owner's first worker stays active with its successor
unbound. Releasing the remaining response drains the second owner's successor.
Request counts must be exactly 2, then 3, then 4. A final recovery must admit
nothing. The test observes which owner completes first rather than assuming
scheduler order. Existing fixture observation bounds detect a stalled test;
Promise barriers, rather than elapsed time, control dispatch/completion order.

The existing queue-only claim test comment is corrected to describe its actual
scope. Eio fibers do not establish multi-domain CAS contention. This new control
proves overlapping production owner lifecycles, not a multicore stress test.

Source hashes are in `source-sha256.json`. OCaml parsing and whitespace checks
passed. Two independent source reviews and response review passed at
`33bb1b7efce4bf3546cb8d65973a66b48ee315f6`; these are source assessments, not
formal GitHub approval. [Selected run 40227874157](https://github.com/jeong-sik/masc/actions/runs/40227874157)
was dispatched on that head for `test_hitl_summary_worker` with `minimal=true`.
Its execution outcome has not yet been read when this record is written. No local Dune build/typecheck was run.

This does not prove process restart, every persistence fault, live provider or
connector behavior, installation, deployment, or completion of all #25860
members. The existing uncertainty controls remain distinct from this positive
conclusive-terminalization control.
