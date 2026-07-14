(** Active-only transcript checkpoint for direct Keeper chat requests.

    This module is subordinate to {!Keeper_msg_async}: it never owns queue
    receipts, request execution, or terminal request truth.  It only closes the
    two crash windows around the direct request's user and assistant transcript
    rows.  Once the transcript is committed and the caller presents a durable
    terminal settlement from [Keeper_msg_async], the checkpoint is removed.

    Records live in a versioned direct-only directory.  The retired
    [.chat-deliveries] namespace is deliberately outside this module's read,
    inventory, and migration surface.

    Mutations and exact loads address one request filename and never inventory
    a directory.  {!inspect_lane} is the explicit per-Keeper recovery boundary;
    malformed active or staging entries quarantine only that lane. *)

module Request_id = Keeper_chat_delivery_identity.Request_id

type accepted_payload =
  { keeper_name : string
  ; submitted_by : string
  ; user_content : string
  ; user_attachments : Keeper_chat_store.attachment list
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : Keeper_chat_store.speaker
  }

type request_result =
  { ok : bool
  ; body : string
  ; data : Yojson.Safe.t option
  }

type transcript_effect =
  | Assistant_reply of
      { content : string
      ; blocks : Keeper_chat_store.chat_block list option
      ; turn_ref : Ids.Turn_ref.t option
      }
  | Transport_failure of { content : string }
  | No_assistant_reply

type staged_effect =
  { request_result : request_result
  ; transcript_effect : transcript_effect
  }

type phase =
  | Prepared
  | User_row_committed of { user_row_id : string }
  | Running of { user_row_id : string }
  | Effect_staged of
      { user_row_id : string
      ; staged : staged_effect
      }
  | Transcript_committed of
      { user_row_id : string
      ; staged : staged_effect
      ; transcript_row_id : string
      }

type t = private
  { schema_version : int
  ; revision : int64
  ; request_id : Request_id.t
  ; payload : accepted_payload
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  }

type phase_kind =
  | Prepared_phase
  | User_row_committed_phase
  | Running_phase
  | Effect_staged_phase
  | Transcript_committed_phase

type mutation_operation =
  | Prepare
  | Commit_user_row
  | Mark_running
  | Stage_effect
  | Commit_transcript

type publication =
  | Not_published
  | Published_indeterminate

type persistence_failure =
  { operation : mutation_operation
  ; request_id : Request_id.t
  ; target_revision : int64
  ; publication : publication
  ; detail : string
  }

type transcript_slot =
  | User_transcript
  | Assistant_transcript

type async_terminal_rejection =
  | Nonterminal_status of Keeper_msg_async.request_status
  | Volatile_terminal
  | Projection_failure of Keeper_msg_async.load_result

type removal_failure =
  { removed : bool
  ; detail : string
  }

type error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string
  | Invalid_request_id of string
  | Invalid_payload of string
  | Already_exists of string
  | Not_found of string
  | Read_failed of string
  | Decode_failed of string
  | Record_not_regular of string
  | Record_identity_changed of string
  | Record_grew_during_read of string
  | Record_too_large_for_runtime of string
  | Identity_mismatch
  | Revision_conflict of
      { expected : int64
      ; actual : int64
      }
  | Revision_exhausted
  | Invalid_transition of
      { expected : phase_kind
      ; actual : phase_kind
      }
  | Invalid_effect of string
  | Transcript_failed of
      { slot : transcript_slot
      ; detail : string
      }
  | Persistence_failed of persistence_failure
  | Async_terminal_rejected of async_terminal_rejection
  | Async_terminal_identity_mismatch
  | Removal_requires_transcript_commit of phase_kind
  | Removal_failed of removal_failure

val error_to_string : error -> string
val phase_kind : phase -> phase_kind
val phase_kind_to_string : phase_kind -> string

val prepare :
  base_path:string ->
  request_id:Request_id.t ->
  payload:accepted_payload ->
  now:float ->
  (t, error) result

(** Idempotently append the accepted user row, then advance the checkpoint.
    A crash after the append but before checkpoint publication is safe to retry:
    the transcript store's exact direct-request slot returns the same row id. *)
val commit_user_row :
  base_path:string -> identity:t -> now:float -> (t, error) result

val mark_running :
  base_path:string -> identity:t -> now:float -> (t, error) result

(** Persist the terminal effect before any assistant transcript append. *)
val stage_effect :
  base_path:string ->
  identity:t ->
  staged:staged_effect ->
  now:float ->
  (t, error) result

(** Idempotently append the staged transcript effect, then advance to
    [Transcript_committed]. [No_assistant_reply] commits the already-durable
    user row as the transcript checkpoint and appends no synthetic reply. *)
val commit_transcript :
  base_path:string -> identity:t -> now:float -> (t, error) result

val load :
  base_path:string ->
  keeper_name:string ->
  request_id:Request_id.t ->
  (t, error) result

(** Opaque evidence that the exact direct request reached a durably committed
    terminal state in [Keeper_msg_async].  Construct this only from the
    [on_worker_settled] callback's typed settlement. *)
type async_terminal_proof

val prove_async_terminal :
  base_path:string ->
  identity:t ->
  Keeper_msg_async.worker_settlement ->
  (async_terminal_proof, error) result

(** Remove the active checkpoint only when it is still the exact supplied
    [Transcript_committed] record and [proof] is bound to the same canonical
    base path, Keeper, caller, and request id.  A post-unlink directory-fsync
    failure reports [Removal_failed {removed=true; _}] and is never silently
    converted to success. *)
val remove_after_async_terminal :
  base_path:string ->
  identity:t ->
  proof:async_terminal_proof ->
  (unit, error) result

type lane_area =
  | Active_records
  | Atomic_staging

type quarantine_reason =
  | Directory_boundary_rejected of string
  | Directory_inventory_failed of string
  | Unexpected_staging_entry
  | Invalid_active_filename of string
  | Active_entry_not_regular
  | Active_entry_unreadable of error
  | Filename_request_mismatch
  | Keeper_payload_mismatch

type quarantine_artifact =
  { area : lane_area
  ; path : string
  ; reason : quarantine_reason
  }

type lane_inventory =
  | Ready of t list
  | Quarantined of
      { recoverable : t list
      ; artifacts : quarantine_artifact list
      }

(** Inventory only one Keeper's direct checkpoint lane.  This is the sole
    directory-scan API and is intentionally not used by mutation hot paths. *)
val inspect_lane :
  base_path:string -> keeper_name:string -> (lane_inventory, error) result

module For_testing : sig
  type io

  val make_io :
    ?before_durable_write:(Keeper_fs.durable_write_stage -> unit) ->
    ?before_durable_remove:(Keeper_fs.durable_remove_stage -> unit) ->
    unit ->
    io

  val prepare :
    io ->
    base_path:string ->
    request_id:Request_id.t ->
    payload:accepted_payload ->
    now:float ->
    (t, error) result

  val commit_user_row :
    io -> base_path:string -> identity:t -> now:float -> (t, error) result

  val mark_running :
    io -> base_path:string -> identity:t -> now:float -> (t, error) result

  val stage_effect :
    io ->
    base_path:string ->
    identity:t ->
    staged:staged_effect ->
    now:float ->
    (t, error) result

  val commit_transcript :
    io -> base_path:string -> identity:t -> now:float -> (t, error) result

  val remove_after_async_terminal :
    io ->
    base_path:string ->
    identity:t ->
    proof:async_terminal_proof ->
    (unit, error) result

  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, error) result

  val active_path :
    base_path:string ->
    keeper_name:string ->
    request_id:Request_id.t ->
    (string, error) result

  val active_dir :
    base_path:string -> keeper_name:string -> (string, error) result

  val staging_dir :
    base_path:string -> keeper_name:string -> (string, error) result
end
