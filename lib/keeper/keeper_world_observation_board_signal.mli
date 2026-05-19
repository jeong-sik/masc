(** Board signal payload parser for keeper world observation. *)

val of_stimulus_payload : string -> Board_dispatch.keeper_board_signal option
