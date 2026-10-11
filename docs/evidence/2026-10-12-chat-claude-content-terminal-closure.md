# Claude observed content terminal closure

Base: `071d7e3610d7d009ef4f6a063705f0533f52bac6`.

Claude root partial-stream blocks close on content_block_stop or full matching
envelope completion. The result path can return successful Turn_finished without
closing a partial block that received neither boundary. Keeper previously swept
no content indexes at this terminal boundary, leaving observed thinking open.

The Keeper projection now closes recorded text/thinking content indexes via its
existing idempotent stop_content before MessageStop. Explicit closures are not
repeated; no hidden reasoning or success outcome is invented. Child content and
native/dynamic tool projections are unchanged.

The process fixture adds a measured full text response, followed by an exposed
partial thinking block without stop or matching full envelope, then result.
Its assertion requires forwarded reasoning and one stop per observed index.
This checks SSE lifecycle, not TUI rows, snapshots or display strings.

Syntax-only parsing and whitespace checks passed. The process fixture has not
been executed. No Dune build, CI, formal approval, installed runtime or screenshot
verification is claimed. Independent review requested. Failed-result/cancellation
and native/dynamic asynchronous boundaries remain incomplete.
