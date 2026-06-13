(** Re-export facade: exposes [Masc_board_handlers.Board] as the bare
    [Board] module in the main [masc] library namespace.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [Board] without qualifying through
    [Masc_board_handlers.Board].  Do not add logic here; this file is
    a pure forwarding shim. *)

include Masc_board_handlers.Board
