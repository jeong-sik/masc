(** Coord task scheduling — claim pool gating, verification block
    state, and the [claim_next] / [release_stale_claims] entries. *)

open Masc_domain
include module type of Coord_utils
include module type of Coord_state

(** Lifecycle state of a verification request, used by the claim
    gate to decide whether a task can be reclaimed. *)
type verification_claim_state =
  [ `Pending | `Assigned | `Passed | `Rejected ]

val task_status_label : Masc_domain.task_status -> string
val task_is_claim_pool_candidate : Masc_domain.task -> bool
val task_is_primary_claim_pool_candidate : Masc_domain.task -> bool
val task_is_soft_reclaim_candidate : Masc_domain.task -> bool

val verification_claim_state_of_status :
  Coord_verification_store.request_status -> verification_claim_state

val latest_verification_status_by_task :
  config -> (string, float * verification_claim_state) Hashtbl.t

val verification_blocks_claim :
  (string, 'a * verification_claim_state) Hashtbl.t ->
  Masc_domain.task -> bool

val task_required_tools : Masc_domain.task -> string list
val string_list_contains : string list -> string -> bool

val required_tools_allowed :
  ?agent_tool_names:string list -> string list -> bool

val underscore_name : string -> string
val hyphen_name : string -> string
val keeper_name_from_agent_name : string -> string option

val agent_record_keeper_name :
  config -> agent_name:string -> string option

val keeper_receipt_candidate_names :
  config -> agent_name:string -> string list

val directory_exists : string -> bool
val directory_entries : string -> string list
val jsonl_files_under : string -> string list
val last_nonempty_line : string -> string option

val latest_json_in_receipt_dir : string -> Yojson.Safe.t option

val json_member_path : string list -> Yojson.Safe.t -> Yojson.Safe.t
val json_raw_string_path : string list -> Yojson.Safe.t -> string option
val json_string_path : string list -> Yojson.Safe.t -> string option
val receipt_sort_key : Yojson.Safe.t -> string

val latest_execution_receipt_json :
  config -> agent_name:string -> Yojson.Safe.t option

val json_string_list : string -> Yojson.Safe.t -> string list

val latest_receipt_blocks_required_tool_claim :
  config -> agent_name:string -> required_tools:string list -> bool

val agent_current_task_matches_backlog :
  Masc_domain.backlog -> agent_name:string -> string -> bool

val reconcile_agent_current_task_with_backlog :
  config -> agent_name:string -> Masc_domain.backlog -> unit

val claim_next_r :
  config ->
  agent_name:string ->
  ?agent_tool_names:string list ->
  ?exclude_task_ids:string list ->
  ?task_filter:(Masc_domain.task -> bool) ->
  unit ->
  Masc_domain.claim_next_result

val claim_next : config -> agent_name:string -> string

val release_stale_claims :
  config -> ttl_seconds:float -> (string * string) list
