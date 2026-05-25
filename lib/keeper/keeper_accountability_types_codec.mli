type claim_kind =
  Keeper_accountability_claim_types.claim_kind =
    Task_commitment
  | Completion_claim
type claim_status =
  Keeper_accountability_claim_types.claim_status =
    Pending
  | Supported
  | Unsupported
  | Expired
  | Partial
type claim_event = {
  claim_id : string;
  agent_name : string;
  keeper_name : string;
  trace_id : string option;
  turn_number : int option;
  task_id : string option;
  kind : claim_kind;
  subject : string;
  surface : string;
  created_at : string;
  evidence_refs : string list;
  synthetic : bool;
}
type resolution_event = {
  claim_id : string;
  agent_name : string option;
  keeper_name : string option;
  task_id : string option;
  kind : claim_kind option;
  subject : string option;
  status : claim_status;
  resolved_at : string;
  reason : string option;
  supporting_evidence_refs : string list;
}
type claim_snapshot = {
  claim : claim_event;
  resolution : resolution_event option;
}
val store_cache : (string, Dated_jsonl.t) Hashtbl.t
val store_cache_mu : Eio.Mutex.t
val window_read_count_for_testing_ref : int option ref
val task_commitment_expiry_sec : float
val completion_claim_expiry_sec : float
val dedupe_window_sec : float
val summary_window_days : int
val claim_kind_to_string :
  Keeper_accountability_claim_types.claim_kind -> string
val claim_kind_of_string :
  string -> Keeper_accountability_claim_types.claim_kind option
val claim_status_to_string :
  Keeper_accountability_claim_types.claim_status -> string
val claim_status_of_string :
  string -> Keeper_accountability_claim_types.claim_status option
val normalize_refs : string list -> String.t list
val is_keeper_agent_name : string -> bool
val accountability_emit_skip_metric : string
val record_emit_skip : kind:string -> reason:string -> unit
val keeper_name_of_agent : string -> string
val normalize_keeper_name : string -> string
val accountability_dir : string -> string
val get_store : Coord_query.config -> Dated_jsonl.t
val json_string_opt : string -> Yojson.Safe.t -> string option
val json_int_opt :
  'a ->
  [> `Assoc of
       ('a * [> `Float of float | `Int of int | `Intlit of string ]) list ] ->
  int option
val json_bool : string -> default:bool -> Yojson.Safe.t -> bool
val option_string_field :
  'a -> string option -> ('a * [> `String of string ]) list
val option_int_field : 'a -> 'b option -> ('a * [> `Int of 'b ]) list
val option_claim_kind_field :
  'a ->
  Keeper_accountability_claim_types.claim_kind option ->
  ('a * [> `String of string ]) list
val claim_event_to_json :
  claim_event ->
  [> `Assoc of
       (string *
        [> `Bool of bool
         | `Int of int
         | `List of [> `String of string ] list
         | `String of string ])
       list ]
val resolution_event_to_json :
  resolution_event ->
  [> `Assoc of
       (string *
        [> `List of [> `String of string ] list | `String of string ])
       list ]
val event_date_string : float -> string
val iso8601_of_unix : float -> string
val claim_event_of_json : Yojson.Safe.t -> claim_event option
val resolution_event_of_json : Yojson.Safe.t -> resolution_event option
val read_window_entries : Coord_query.config -> Yojson.Safe.t list
