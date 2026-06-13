(** Agent/economy adapter for neutral Board side-effect hooks. *)

val install : unit -> unit
(** Install the concrete economy and Thompson-sampling observer for board
    side-effect hooks. *)
