# IDE consumer contract (M1)

An editor extension talks to masc over HTTP. M1 is one write and three
reads: the IDE files questions as tasks, watches keeper activity on
files, and shows who is around. Everything else on this plane is a
later milestone, named at the bottom so an extension knows what not
to build against yet.

All routes live under `/api/v1/ide/`. Reads mix public and
admin-gated routes; the one write requires a Bearer [REDACTED] with the
`CanAdmin` permission, like every mutation on this plane.

## Asking the fleet: POST /api/v1/ide/asks

Request body (JSON object):

| Field | Required | Meaning |
| --- | --- | --- |
| `question` | yes | What the operator is asking. Non-blank; becomes the task title. |
| `file_path` | no | Workspace-relative file under discussion, e.g. `lib/a.ml`. |
| `line` | no | Positive integer; requires `file_path`. |
| `context` | no | Free text the keeper reads after the file reference. |
| `priority` | no | Integer 1–5, default 3. |

Unknown fields are ignored. A mistyped `line` or `priority`, a blank
`question`, a `line` without a `file_path`, or a body that is not a
JSON object is `400` with `{"ok":false,"code":"invalid_ask",...}`.
An uninitialized workspace is `500` with code
`ask_store_unavailable`; initialize the workspace first.

Success is `202`:

```json
{"ok": true, "data": {"ask_id": "task-9f3a…", "status": "todo"}}
```

The ask is a Todo task created by `ide`, with the question as its
title and `IDE ask from <file>:<line>` plus the context as its
description. Routing is pool-wide: tasks carry no pre-assignment,
so the body names no keeper and a keeper becomes the assignee by
claiming. The fleet's existing pickup does the rest -- a keeper
claims the task, works it, and completes it.

To read the answer back, poll the task like any other: the dashboard
task detail route for status, the task history route for the trail.
`ask_id` is the task id both routes take.

## Watching files: GET /api/v1/ide/file-activity

`?file_path=<path>&window_hours=<n>&repo_id=<id>`. Every row a
keeper wrote touching the file (before/after strings, whole file
bodies) over the window. Admin-gated: the same content the keeper
file-changes route keeps behind `CanAdmin`.

## Watching keepers: GET /api/v1/ide/events

`?kind=tool|turn&keeper_id=<id>&limit=<n>&offset=<m>`. Tool and
turn events for a codebase, newest first, paginated (max limit
200). Public read. An unknown codebase answers empty, not an
error.

## Who is around: GET /api/v1/ide/presence

Keeper roster with status and last-seen timestamps. Public read.

## Memos

Keepers leave line memos with `keeper_ide_annotate`: a comment
above a line, shaped `masc(AUTHOR): TEXT` or
`masc(AUTHOR) KIND: TEXT` where KIND is `decision`, `question`,
`bookmark`, or the plain `comment`. The memo travels with the
file into diffs and reviews, and it moves with the line below it
when the file is edited -- which is why there is no memo index
endpoint: a line number stored elsewhere goes stale on edit.
Render memos by reading the file.

## Not M1

- Targeted asks (name a keeper, or the keeper attached to this codebase).
- Operator focus ingestion (what file/selection the operator is viewing).
- Push delivery (the IDE polls; there is no event stream to subscribe to).
