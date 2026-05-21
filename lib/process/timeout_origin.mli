(** Typed timeout origin labels shared by timeout telemetry emitters. *)

type t =
  | Slot_wait
  | Spawn
  | Command
  | Llm_response
  | Dashboard_refresh
  | Health_probe
  | Other of string

val to_label : t -> string
(** Stable wire label for metrics and JSON payloads. *)

val standard : t list
(** Bounded, first-class origins with stable labels. *)

val process_origins : t list
(** Origins emitted by [Process_eio] subprocess timeouts. *)

val is_process_origin : t -> bool
(** True for [Slot_wait], [Spawn], and [Command]. *)
