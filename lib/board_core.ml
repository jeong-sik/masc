(** Re-export facade: exposes [Masc_board_handlers.Board_core] as the bare
    [board_core] module in the main [masc] library namespace.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [board_core] without qualifying through
    [Masc_board_handlers.Board_core].  Do not add logic here; this file is
    a pure forwarding shim. *)

include Masc_board_handlers.Board_core
