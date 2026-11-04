val keeper_costs_max_window_minutes : int
(** The longest [window] GET /api/v1/dashboard/keeper-costs accepts. *)

val keeper_costs_window_of_query : string option -> (int, string) result
(** The [window] query parameter: absent is the default (the maximum); a
    value that is not an integer in [1, keeper_costs_max_window_minutes] is
    an error, never clamped. *)

val keeper_cost_aggregates_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  window_minutes:int ->
  now_ts:float ->
  Yojson.Safe.t
(** Each listed Keeper's metrics day files of the widest window are kept for
    the workspace between calls: a call folds only the rows each file gained
    since the last, and drops the Keepers it does not list. *)

val keeper_costs_next_change : base_path:string -> now:float -> float option
(** The earliest instant after [now] at which the default window's answer
    changes with no new row: a kept row's time or a kept day file's day
    leaving the window. [None] when nothing kept is in it. *)

val install_keeper_costs_kept_observer : (base_path:string -> unit) -> unit
(** Called after every {!keeper_cost_aggregates_json}, which may have kept
    rows whose change instant is earlier than any kept before. *)

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
