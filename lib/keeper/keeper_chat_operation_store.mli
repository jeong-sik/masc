(** Strict durable operation log for one Keeper's chat lane.

    A Keeper owner creates one store, owns its SQLite connection, and is the
    only writer. The store has no lease, receipt, recovery, or revision
    vocabulary. *)

type source =
  | Dashboard of { thread_id : string }
  | Discord of
      { channel_id : string
      ; user_id : string
      }
  | Slack of
      { channel_id : string
      ; user_id : string
      ; user_name : string
      ; team_id : string option
      ; thread_ts : string option
      }

type input =
  { content : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; attachments : Keeper_chat_store.attachment list
  ; submitted_at : float
  ; source : source
  ; user_row_origin : Keeper_chat_store.user_row_origin
  }

type edit_input =
  { content : string
  ; user_blocks : Keeper_multimodal_input.user_input_block list
  ; attachments : Keeper_chat_store.attachment list
  }

type failure_kind =
  | Interrupted_by_restart
  | Shutdown_interrupted
  | Turn_failed
  | No_visible_reply
  | Transcript_persist_failed
  | Connector_unavailable
  | Delivery_failed
  | Terminal_effect_failed
  | Internal_error

type state =
  | Queued
  | Running of { started_at : float }
  | Succeeded of
      { completed_at : float
      ; outcome_ref : string
      }
  | Failed of
      { completed_at : float
      ; kind : failure_kind
      ; detail : string
      ; outcome_ref : string option
      }
  | Cancelled of { completed_at : float }

type operation =
  { operation_id : string
  ; admission_digest : string
  ; execution_digest : string
  ; sequence : int64
  ; input : input option
  ; state : state
  }

type error =
  | Unknown_operation of string
  | Not_queued of
      { operation_id : string
      ; state : state
      }
  | Idempotency_conflict of string
  | Invalid_input of string
  | Store_unavailable of string

type submit_result =
  | Accepted of operation
  | Existing of operation

type t

val open_ : base_path:string -> keeper_name:string -> (t, error) result
(** Open or create [chat-operations.sqlite3] and strictly validate its schema.
    No older database is recognized or migrated. *)

val close : t -> (unit, error) result

val submit : t -> operation_id:string -> input -> (submit_result, error) result
(** Durably insert before returning [Accepted]. Reusing an ID returns the
    existing operation only when the canonical input digest is identical. *)

val lookup : t -> operation_id:string -> (operation, error) result

val list_queued :
  t -> after_sequence:int64 option -> limit:int -> (operation list, error) result

val start_next : t -> started_at:float -> (operation option, error) result
(** Atomically transition the FIFO head from [Queued] to [Running]. *)

val edit : t -> operation_id:string -> edit_input -> (operation, error) result
val move_to_end : t -> operation_id:string -> (operation, error) result
val cancel : t -> operation_id:string -> completed_at:float -> (operation, error) result

val succeed :
  t ->
  operation_id:string ->
  completed_at:float ->
  outcome_ref:string ->
  (operation, error) result

val fail :
  t ->
  operation_id:string ->
  completed_at:float ->
  kind:failure_kind ->
  detail:string ->
  outcome_ref:string option ->
  (operation, error) result

val settle_interrupted : t -> completed_at:float -> (int, error) result
(** In one transaction, close every persisted [Running] operation as
    [Failed Interrupted_by_restart]. Queued and terminal rows are unchanged. *)

val failure_kind_to_string : failure_kind -> string
val error_to_string : error -> string

module For_testing : sig
  type commit_fault =
    | Before_commit
    | After_commit

  val database_path : base_path:string -> keeper_name:string -> (string, error) result
  val fail_next_commit : commit_fault -> unit
end
