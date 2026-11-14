# Operator lesson

Writes short lessons for the operator from the workspace's own records: Board
posts and comments, commits and the files they change, wiki pages, and merged
pull requests with their reviews. Every paragraph quotes the record it rests
on, and a quote that is not in its record drops the scene.

One `compose {scenes}` action is one lesson:

1. The package reads each granted source from where the last outlined lesson
   stopped, or from the binding's `since`.
2. The `outline` output names what each scene is about and the records it may
   quote. An entry that names a record the lesson did not read is dropped.
3. The `scene` output writes one scene per entry, from that entry's records
   only. A scene that fails is recorded with its reason and is not asked for
   again; the other scenes are not affected.

The package asks the operator nothing and calls no Keeper.

- `lesson_log.py`: the events, their closed reasons, and the fold into sessions.
- `lesson_flow.py`: the listing and the consumption of each result, including
  the quote check of every paragraph against the record bytes the host retained.
- `lesson_projection.py`: the rows of `lesson/scenes`, `lesson/sessions` and `lesson/measures`.
  `lesson/scenes` holds the scenes of one lesson, the one that wrote the newest scene (#51941).
- `server.py`: the MCP worker; it reads `max_reply_bytes` from `lane.toml`.

Reading records, pins and the log file are the shared `../records.py`, which
the operator quiz uses too. The host mounts this directory at `/addon`; the
image carries Python and the shared `protocol.py` and `records.py` only.

The log is `/state/operator-lesson/log.jsonl` on the installation's
persistent volume. Rows are computed from it at every observation.

Turning it on and reading the results: [operator lesson guide](../../docs/guides/operator-lesson.md).
Design: [RFC](../../docs/rfc/RFC-operator-lesson-lane.md).
