open Keeper_types

val running_keepers : unit -> int
val keeper_keepalive_running : string -> bool
val start_keepalive :
  ?proactive_warmup_sec:int -> 'a context -> keeper_meta -> unit
val stop_keepalive : string -> unit
