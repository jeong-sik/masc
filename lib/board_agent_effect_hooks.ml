(** Re-export facade: exposes [Masc_board_handlers.Board_agent_effect_hooks] as the bare
    [board_agent_effect_hooks] module in the main [masc] library namespace.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [board_agent_effect_hooks] without qualifying through
    [Masc_board_handlers.Board_agent_effect_hooks].  Do not add logic here; this file is
    a pure forwarding shim. *)

include Masc_board_handlers.Board_agent_effect_hooks
