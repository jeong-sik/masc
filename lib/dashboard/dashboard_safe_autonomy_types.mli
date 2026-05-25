type domain_level =
  Dashboard_safe_autonomy_level.domain_level =
    Pass
  | Warn
  | Fail
type evidence_ref = { kind : string; label : string; value : string; }
type finding = {
  reason_code : string;
  domain_id : string;
  severity : domain_level;
  keeper_name : string option;
  summary : string;
  human_action_required : bool;
  suggested_next_action : string;
  evidence_refs : evidence_ref list;
}
type keeper_domain = {
  id : string;
  label : string;
  weight : int;
  status : domain_level;
  score : float;
  summary : string;
  evidence_refs : evidence_ref list;
}
type live_tool_stats = { calls : int; success_pct : float; }
type approval_stats = {
  count : int;
  oldest_wait_sec : float option;
  entries : Yojson.Safe.t list;
}
type activity_stats = { count : int; last_ts : float option; }
type artifact_state = {
  latest_path : string;
  history_path : string;
  fingerprint : string;
  history_appended : bool;
}
type keeper_snapshot = {
  meta : Keeper_types.keeper_meta;
  sandbox : Keeper_sandbox.t;
  repo_readiness : Yojson.Safe.t;
  bench_recommendation :
    Keeper_benchmark_canary.recommendation option;
  live_tool_stats : live_tool_stats option;
  approval : approval_stats;
  activity : activity_stats;
  tool_domain : keeper_domain;
  sandbox_domain : keeper_domain;
  approval_domain : keeper_domain;
  cascade_domain : keeper_domain;
  audit_domain : keeper_domain;
  findings : finding list;
}
val tool_domain_id : string
val sandbox_domain_id : string
val approval_domain_id : string
val cascade_domain_id : string
val audit_domain_id : string
val domain_catalog : (string * string * int) list
val level_to_string :
  Dashboard_safe_autonomy_level.domain_level -> string
val level_rank : Dashboard_safe_autonomy_level.domain_level -> int
val worse_level :
  Dashboard_safe_autonomy_level.domain_level ->
  Dashboard_safe_autonomy_level.domain_level ->
  Dashboard_safe_autonomy_level.domain_level
val worst_level :
  Dashboard_safe_autonomy_level.domain_level list ->
  Dashboard_safe_autonomy_level.domain_level
val normalize_string_opt : string option -> string option
val float_opt_to_json : 'a option -> [> `Float of 'a | `Null ]
val string_opt_to_json : 'a option -> [> `Null | `String of 'a ]
val evidence_ref_json :
  evidence_ref -> [> `Assoc of (string * [> `String of string ]) list ]
val finding_json :
  finding ->
  [> `Assoc of
       (string *
        [> `Bool of bool
         | `List of
             [> `Assoc of (string * [> `String of string ]) list ] list
         | `Null
         | `String of string ])
       list ]
val keeper_domain_json :
  keeper_domain ->
  [> `Assoc of
       (string *
        [> `Float of float
         | `Int of int
         | `List of
             [> `Assoc of (string * [> `String of string ]) list ] list
         | `String of string ])
       list ]
val base_evidence_ref : string -> string -> string -> evidence_ref
val approval_stats_of_pending_json :
  [< `Assoc of 'a
   | `Bool of 'b
   | `Float of 'c
   | `Int of 'd
   | `Intlit of 'e
   | `List of Yojson.Safe.t list
   | `Null
   | `String of 'f ] ->
  (string, approval_stats) Hashtbl.t
val activity_stats_by_keeper :
  Keeper_types.keeper_meta list ->
  Activity_feed.activity_item list ->
  (string, activity_stats) Hashtbl.t * (string, string) Hashtbl.t
val bench_recommendation_path : unit -> string
val candidate_keeper_profiles : string -> string list
val recommendation_for_keeper :
  Keeper_benchmark_canary.manifest option ->
  keeper_name:string ->
  Keeper_benchmark_canary.recommendation option
val live_tool_stats_by_keeper :
  unit -> (string, live_tool_stats) Hashtbl.t * Yojson.Safe.t
val transport_health_status :
  Yojson.Safe.t -> domain_level * string * string option
val domain_definition : String.t -> String.t * int
val make_domain :
  id:String.t ->
  status:domain_level ->
  score:float ->
  summary:string -> evidence_refs:evidence_ref list -> keeper_domain
val make_finding :
  reason_code:string ->
  domain_id:string ->
  severity:domain_level ->
  ?keeper_name:string ->
  summary:string ->
  human_action_required:bool ->
  suggested_next_action:string ->
  evidence_refs:evidence_ref list -> unit -> finding
