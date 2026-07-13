(** Board_tool — MCP tool family for the internal board (facade).

    Stage 10 split: this module is a thin facade over five primary
    submodules — and three sub-domain helpers — that preserve every
    public surface pinned by the .mli:

    Primary (per plan §Stage 10):
    - {!Board_tool_format}    — formatters, arg coercion helpers,
                                sort-order parser,
                                Board_error renderer, Yojson boundary.
    - {!Board_tool_cache}     — TTL cache for [masc_board_list]
                                payloads and its invalidator.
    - {!Board_tool_handlers}  — agent-lookup callback, SOUL-evolution
                                hook, vote / comment_vote / reaction /
                                stats / search / profile / hearths /
                                delete / board_cleanup handlers.
    - {!Board_tool_registry}  — tool schema list ({!tools}) advertised
                                to MCP clients.
    - {!Board_tool_dispatch}  — [handle_tool] routing and
                                {!Tool_dispatch} registration.

    Sub-domain (extracted to satisfy the new-file LOC cap):
    - {!Board_tool_post}      — post lifecycle (create / list / get /
                                comment_add).
    - {!Board_tool_sub_board} — sub-board CRUD handlers.
    - {!Board_tool_curation}  — curation_read / curation_submit
                                handlers.

    The includes below preserve the public value identities, including
    [sort_order]. *)

include Board_tool_format
include Board_tool_cache
include Board_tool_handlers
include Board_tool_post
include Board_tool_sub_board
include Board_tool_curation
include Board_tool_schemas
include Board_tool_registry
include Board_tool_dispatch
