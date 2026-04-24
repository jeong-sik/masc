(** Keeper_runtime_resolved — freeze keeper runtime knobs after bootstrap.

    Values resolve with the existing precedence order:
    environment > keeper_runtime.toml boot override > compiled default.

    Before [init] is called, readers see a live snapshot of the current env/boot
    override state. After [init], reads are frozen to the bootstrap snapshot so
    late env drift cannot change keeper execution behaviour. *)

type source =
  | Env
  | Toml
  | Default
  | Derived

type 'a field = {
  value : 'a;
  source : source;
}

type t = {
  bootstrap_max_active_keepers : int field;
  reactive_max_turns_per_call : int field;
  autonomous_max_turns_per_call : int field;
  reactive_max_idle_turns : int field;
  autonomous_max_idle_turns : int field;
  turn_timeout_sec : float field;
  admission_wait_timeout_sec : float field;
  oas_timeout_override_sec : float option field;
  oas_timeout_per_1k : float field;
  oas_timeout_per_turn : float field;
}

val max_turns_per_call_min : int
val max_turns_per_call_max : int

val init : unit -> unit
val reset_for_tests : unit -> unit
val current : unit -> t

val source_to_string : source -> string
val to_yojson : t -> Yojson.Safe.t

val bootstrap_max_active_keepers : unit -> int
val reactive_max_turns_per_call : unit -> int
val autonomous_max_turns_per_call : unit -> int
val reactive_max_idle_turns : unit -> int
val autonomous_max_idle_turns : unit -> int
val turn_timeout_sec : unit -> float
val admission_wait_timeout_sec : unit -> float
val oas_timeout_for_estimated_input_tokens_with_turn_budget :
  estimated_input_tokens:int ->
  max_turns:int ->
  float

val oas_timeout_for_estimated_input_tokens :
  estimated_input_tokens:int ->
  float
