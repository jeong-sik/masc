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

type decision_log_read_error = {
  keeper : string;
  cause : Keeper_memory_recall_exn_class.t;
}

type decisions_observation = {
  json : Yojson.Safe.t;
  read_errors : decision_log_read_error list;
}

val keeper_decisions_observation :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  decisions_observation
(** One original tail read per listed Keeper supplies both the normalized
    chronology and its typed read failures. Missing/empty files are successful
    empty tails; individual malformed JSON rows retain their skip policy.
    A returned tail I/O error keeps its Keeper and bounded original class,
    without a second read or an existence preflight in this projection. *)

val keeper_decisions_json :
  config:Workspace.config ->
  keepers:Keeper_meta_contract.keeper_meta list ->
  ?limit:int ->
  unit ->
  Yojson.Safe.t
(** Display facade over the same observation. Read failures are logged and
    retain this facade's original readable-row projection; Current HTTP uses
    {!keeper_decisions_observation} to require a complete successful feed. *)
