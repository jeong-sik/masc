# Current context on a resumed Codex Keeper

The installed `2578d7fec3061b0a8a05301eb465ae0521ce5461` runtime composed
20,087 bytes of developer instructions for exhibit-designer at 11:35:43 UTC.
The corresponding native turn nevertheless declared that no work remained.
Its persisted Codex conversation contains only the three initial developer
items from 10:06:09 UTC; the 11:35:48 UTC user item contains the 131-byte
autonomous cue. The allowlisted observations are in `observed-before.json`.

This is evidence about persisted native history and host composition, not a
capture of the provider's HTTP model request. The raw MASC trace's `prompt`
field alone never described the developer-instruction channel.

The Keeper adapter assembled changing context into `developerInstructions`
on `thread/resume` but did not use the transport's existing
`developer_context` input. The repair injects current developer context on
every turn. A resumed thread also receives the freshly composed Keeper
instructions, so changed instructions become explicit history items.
The existing conversation stays in the same native thread and is not
injected again. The user cue remains user input.

[OpenAI's app-server documentation](https://learn.chatgpt.com/docs/app-server#inject-items-into-a-thread)
states that `thread/inject_items` persists supplied items and includes them
in subsequent model requests. The transport waits for that request's
acknowledgment before submitting `turn/start`.

`test_keeper_codex_current_context` drives the production Keeper adapter
through actual fixture processes. It checks fresh and resumed requests,
changed Keeper instructions, current Task/Goal context, retained thread
identity, omission of repeated history, and refusal to submit a model turn
after context injection fails. This checks transport, not model understanding.
Local validation is parse-only plus `git diff --check`; native execution
belongs to CI. No live Keeper was changed or restarted by this repair.
