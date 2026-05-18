(** Tool_board — MCP tool family for the internal board (facade).

    Stage 10 split: this module is a thin facade over five primary
    submodules — and three sub-domain helpers — that preserve every
    public surface pinned by the .mli:

    Primary (per plan §Stage 10):
    - {!Tool_board_format}    — formatters, arg coercion helpers,
                                sort-order parser,
                                truncated-markdown detector,
                                Board_error renderer, Yojson boundary.
    - {!Tool_board_cache}     — TTL cache for [masc_board_list]
                                payloads and its invalidator.
    - {!Tool_board_handlers}  — agent-lookup callback, SOUL-evolution
                                hook, vote / comment_vote / reaction /
                                stats / search / profile / hearths /
                                delete / board_cleanup handlers.
    - {!Tool_board_registry}  — tool schema list ({!tools}) advertised
                                to MCP clients.
    - {!Tool_board_dispatch}  — [handle_tool] routing and
                                {!Tool_dispatch} registration.

    Sub-domain (extracted to satisfy the new-file LOC cap):
    - {!Tool_board_post}      — post lifecycle (create / list / get /
                                comment_add).
    - {!Tool_board_sub_board} — sub-board CRUD handlers.
    - {!Tool_board_curation}  — curation_read / curation_submit
                                handlers.

    The .mli contract is unchanged. The includes below preserve every
    pinned value identity, including [sort_order] and
    [truncation_signal] constructor re-exports. *)

include Tool_board_format
include Tool_board_cache
include Tool_board_handlers
include Tool_board_post
include Tool_board_sub_board
include Tool_board_curation
include Tool_board_registry
include Tool_board_dispatch
