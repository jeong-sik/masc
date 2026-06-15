(** Keeper_circuit_breaker — Persistent state for idle circuit breaker.

    Tracks consecutive idle turns across keeper restarts to prevent infinite
    polling loops. State persists in .masc/circuit_breaker_state.json. *)

type state = {
  consecutive_idle_turns : int;
  last_reset_ts : float;
  threshold : int;
}

val default_state : threshold:int -> state
val state_file_path : string -> string
val load_state : workspace_base:string -> default:state -> state
val save_state : workspace_base:string -> state:state -> unit
val increment_state : state:state -> state
val reset_state : state:state -> now:float -> state
val should_skip : state:state -> bool
val state_to_json : state:state -> Yojson.Basic.t
val json_to_state : json:Yojson.Basic.t -> state