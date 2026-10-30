(** A safe, change-driven title for the terminal window or tab. *)

type activity =
  | Working
  | Connection of Masc_tui_types.connection_status

type snapshot

val make
  :  activity:activity
  -> keeper_name:string option
  -> runtime_id:string option
  -> workspace:string
  -> snapshot

(** The control-filtered, length-bounded title payload, without its OSC wrapper. *)
val text : snapshot -> string

(** Prefer the live stream, then the visible Keeper when it is in flight,
    then any in-flight Keeper, and finally the visible selection. *)
val select_keeper
  :  live:string option
  -> inflight:string list
  -> visible:string option
  -> string option

type t

val create : unit -> t

(** Best-effort OSC 0 write, only when the projected title changed. *)
val present
  :  t
  -> write:(string -> unit)
  -> flush:(unit -> unit)
  -> snapshot
  -> unit

(** Best-effort empty title after this TUI gives the terminal back. *)
val clear : t -> write:(string -> unit) -> flush:(unit -> unit) -> unit
