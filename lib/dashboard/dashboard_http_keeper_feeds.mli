val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  Yojson.Safe.t

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

val keeper_decisions_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t

type decision_event = {
  ts_unix : float;
  id : string;
  ts : string;
  keeper : string;
  decision_type : string;
  summary : string;
  terminal_reason_code : string option;
  duration_ms : float option;
  evidence_refs : string list;
}
(** Typed projection of a keeper decision-log line. *)

val parse_decision_event : keeper_name:string -> string -> decision_event option
(** Parse one decision-log line into a typed event, defaulting the keeper to
    [keeper_name] when the line omits it. Returns [None] on malformed JSON.
    Exposed for tests. *)

val decision_event_to_yojson : decision_event -> Yojson.Safe.t
(** Render the dashboard payload for a decision event; field set and order match
    the feed output. Exposed for tests. *)

val keeper_memory_log_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
