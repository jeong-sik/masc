(** Re-export facade: exposes [Masc_board_handlers.Board_attachment_meta] as the bare
    [board_attachment_meta] module in the main [masc] library namespace.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [board_attachment_meta] without qualifying through
    [Masc_board_handlers.Board_attachment_meta].  Do not add logic here; this file is
    a pure forwarding shim. *)

include Masc_board_handlers.Board_attachment_meta
