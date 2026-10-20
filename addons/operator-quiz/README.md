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

- `quiz_log.py`: the log's events, the session fold, and the body store.
- `quiz_flow.py`: the listing and the consumption of each result, including
  the quote check of every draft against the record bytes the host retained.
- `quiz_grading.py`: choice verdicts and review items.
- `quiz_projection.py`: the five lanes' rows, R and P.
- `server.py`: the MCP worker; it reads `max_reply_bytes` from `lane.toml`.

The host mounts this directory at `/addon`; the image carries Python and the
shared `protocol.py` only. Turning it on, binding the `author` slot, setting
the times and reading the results: [operator quiz guide](../../docs/guides/operator-quiz.md).
Design: [RFC](../../docs/rfc/RFC-operator-quiz-lane.md).
