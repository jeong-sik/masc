(** Stable references shared by the TUI surfaces. *)

type kind =
  | Board_post
  | Goal
  | Schedule
  | Task
  | Fusion_run
  | Keeper

val reference : kind -> string -> string
(** [reference kind id] returns a control-free [masc://] reference. The
    identifier is percent-encoded as one path segment. *)

val osc52_copy : string -> string
(** [osc52_copy text] returns an OSC 52 clipboard-write sequence. *)
