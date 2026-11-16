# Operator quiz

This package asks the operator multiple-choice questions written from the
workspace's own records: Board posts and comments, and files under a
`repository` grant's paths. A Schedule sends `compose`; the package then asks
the host for what it needs, one host request at a time (`read_records`,
`read_file`, `read_result`, `exact_output author`, `ask`), and the question
appears in Approvals. The answer is graded by its key on arrival.

Every fact lives in one strict log on the installation's persistent volume,
`/state/operator-quiz/log.jsonl`, with the request bodies and read results it
names under `requests/` and `pages/`. What the package lists and what it does
with each result is a function of that log (`quiz_flow.py`), so a restarted
worker lists the same request with the same body. A result is answered
`accepted` only after the event that consumes it is on disk.

Author history scope is retained as domain context alongside its request, rather
than reconstructed from the request message wire. Missing recorded context is
reported as unavailable; original questions, answers and request blobs stay intact.

An installation may bind the `scenes` output of an `operator-lesson`
installation in the same run. The quiz then keeps the pins each lesson output
cited (`lesson_seen`), and a session opened under that binding asks new
questions only from records it read that a lesson cited. That binding also
gives `since`, the lesson's own: a session that follows the lesson reads a
record source from it (`follows_lesson`) until a session that asked has left
a cursor on that source. A quiz that has not asked yet reads every source
from `since`, so the records the lesson cited are read, except a wiki page
edited after the lesson cited it and before the quiz read it: the host
gives the page at its new revision, and a cite names the revision. One that
asked
before the lesson was bound reads on from its cursors, and a record the
lesson cites from before them is not read. A read from `since` that finds
no record leaves no cursor, unless the host passed over items that have no
record (`github_pulls`: commits that are not the merge commit of a pull
request). The cursor goes by `source_id`: a source taken out and put back
is read from the cursor it had, unless a session that had not finished
reading that source when it was taken out asked for that cursor and was
refused (#52372). Then the source is read from the cursor before it, or
from `since`, and a session that asked after that read leaves its own
cursor, even the one refused (#52417).
Design:
[RFC](../../docs/rfc/RFC-operator-quiz-follows-lesson.md).

- `quiz_log.py`: the log's events, the session fold, and the body store.
- `quiz_flow.py`: the listing and the consumption of each result, including
  the quote check of every draft against the record bytes the host retained.
- `quiz_grading.py`: choice verdicts and review items.
- `quiz_projection.py`: the seven lanes' rows, R and P, the scorecard windows and the wrong-answer notes.
- `server.py`: the MCP worker; it reads `max_reply_bytes` from `lane.toml`.

The host mounts this directory at `/addon`; the image carries Python and the
shared `protocol.py` and `records.py` only. Turning it on, binding the `author` slot, setting
the times and reading the results: [operator quiz guide](../../docs/guides/operator-quiz.md).
Design: [RFC](../../docs/rfc/RFC-operator-quiz-lane.md).
