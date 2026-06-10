(** Re-export facade: exposes [Masc_board_handlers.Board_moderation] as the bare
    [board_moderation] module in the main [masc] library namespace.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [board_moderation] without qualifying through
    [Masc_board_handlers.Board_moderation].  Do not add logic here; this file is
    a pure forwarding shim. *)

include Masc_board_handlers.Board_moderation
