(** A recovery retry requires a visible preview followed by a separate input. *)
type t
val create : unit -> t
val observe_frame : t -> visible:bool -> input_pending:bool -> unit
val ready : t -> bool
val withdraw : t -> unit
(** An accepted frame establishes authority only when the change and retry
    instruction are visible and no earlier input is still queued or incomplete. *)
