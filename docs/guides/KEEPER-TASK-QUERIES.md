# Reading tasks without scanning the backlog

`keeper_tasks_list` applies explicit filters before pagination and before building
the recent-task window. All supplied predicates are ANDed. The response's
`matching_count` counts the filtered tasks, not the whole workspace.

| Question | Arguments |
| --- | --- |
| Read known task contracts together | `task_ids=["task-123","task-456"], projection="full"` |
| Find work connected to one Goal | `goal_id="goal-123"` |
| Find one Keeper's ongoing work | `assignee="code-reviewer", status="in_progress"` |
| Find an existing release task | `query="release", status="todo"` |
| Count completed tasks and inspect their timestamps | `status="done", projection="compact"` |

`query` is a literal substring over title and description, ignoring ASCII case.
It does not infer semantic relevance or search receipt bodies. An exact ID or
Goal is preferable when already known. A zero-result query says only that these
filters matched no rows; it does not prove that no related work exists.

The default status selection excludes completed and cancelled tasks, including
when `task_ids` is supplied. Use `include_done=true` to include completed tasks,
or an explicit `status="done"` / `status="cancelled"` selection. `assignee` matches
the performer, including after completion, and never treats a canceller as one.

Compact rows keep identity, priority, lifecycle state, actors and timestamps;
completion notes are available through `projection="full"`. `new_tasks` is an
extra discovery window only on the first page. Continuation pages carry an empty
window and retain the complete ordered page stream. Restart from the first page
to discover new arrivals; paging is not a frozen historical snapshot.

When `truncated=true`, pass `next_cursor` with the same filters and projection.
Changing a filter invalidates that cursor instead of silently restarting it.
For a repeated read of the same selection/page, pass its `revision` as
`if_revision`; `kind="unchanged"` means the prior result still applies. It does
not carry another copy of the rows. Revisions include selection and returned data.

Goal selection reads the authoritative link registry. An unreadable registry is
an error, not an empty result. No Keeper state, task ownership or scheduling
policy changes when using these filters.
