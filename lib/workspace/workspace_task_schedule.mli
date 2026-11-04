(** Workspace task scheduling — claim pool state and the [claim_next] entry. *)

include module type of Workspace_utils
include module type of Workspace_state

val task_status_label : Masc_domain.task_status -> string
val task_is_claim_pool_candidate : Masc_domain.task -> bool

(* Verification-record state does not gate the claim pool. Persisted task
   status is the scheduling authority. *)

val agent_record_keeper_name : config -> agent_name:string -> string option
val keeper_receipt_candidate_names : config -> agent_name:string -> string list
val directory_exists : string -> bool
val directory_entries : string -> string list
val jsonl_files_under : string -> string list
val last_nonempty_line : string -> string option
val latest_json_in_receipt_dir : string -> Yojson.Safe.t option
val json_member_path : string list -> Yojson.Safe.t -> Yojson.Safe.t
val json_raw_string_path : string list -> Yojson.Safe.t -> string option
val json_string_path : string list -> Yojson.Safe.t -> string option
val receipt_sort_key : Yojson.Safe.t -> string
val latest_execution_receipt_json : config -> agent_name:string -> Yojson.Safe.t option

val claim_next_r
  :  config
  -> agent_name:string
  -> ?auto_start:bool
       (** When [true], atomically transitions the claimed task (or an already
           held [Claimed] task) to [InProgress] inside the same [.backlog]
           lock and commit. Default [false]. *)
  -> unit
  -> Masc_domain.claim_next_result
