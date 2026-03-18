(** Trpg_round_run_ctx — Context record for the round-run process_one extraction.

    Bundles all mutable refs and captured values that process_one needs
    from the outer scope of handle_round_run, enabling it to live in
    a separate module (Trpg_round_run_process).

    This module intentionally does NOT include Trpg_handlers to avoid
    leaking round_ctx into the downstream include chain. Types are
    referenced via their defining modules. *)

type round_ctx = {
  ctx : Trpg_types.context;
  store : Trpg_store.t;
  room_id : string;
  phase : string;
  turn_before : int;
  rule_module : string;
  prompt_lang : Trpg_round_prompt.prompt_language;
  keeper_timeout_sec : float;
  local_fallback : bool;
  strict_agent_driven : bool;
  strict_unique_player_reply : bool;
  require_claim : bool;
  dm_persona_override : string option;
  unavailable_sampling : Trpg_round.unavailable_sampling_state;
  (* mutable refs *)
  dm_reply_ref : string option ref;
  seen_player_reply_signatures : (string * string) list ref;
  statuses : Yojson.Safe.t list ref;
  outcome_source_ref : string ref;
  stagnation_level_ref : int ref;
  stagnation_pressure_emitted : bool ref;
  success_count : int ref;
  fallback_count : int ref;
  schema_failures : int ref;
  rule_validation_failures : int ref;
  reprompt_count : int ref;
  player_success_count : int ref;
  player_fallback_count : int ref;
  dm_success : bool ref;
  unavailable_count : int ref;
  timeout_count : int ref;
  state_for_players_ref : Yojson.Safe.t ref;
  appended_events : Trpg_engine_event.t list ref;
}
