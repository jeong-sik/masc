(** Board SSE event -> JSON params projection.

    Wire payload format consumed by the [/sse/board] stream and by
    [test/test_board_sse_canonical_event_type.ml]. *)

val board_sse_event_params : Board_dispatch.board_sse_event -> Yojson.Safe.t
