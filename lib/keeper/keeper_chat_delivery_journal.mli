(** Durable, revision-checked SSOT for Keeper chat delivery.

    Inference and transcript delivery are deliberately separate phases. A
    terminal model/timeout result is persisted before transcript append, and a
    request becomes [Final] only after the exact transcript slot is durable. *)

module Identity = Keeper_chat_delivery_identity

type user_row_origin =
  | Needs_append
  | Already_persisted of { row_id : string }

type accepted_payload =
  { keeper_name : string
  ; submitted_by : string
  ; user_content : string
  ; user_attachments : Keeper_chat_store.attachment list
  ; surface : Surface_ref.t
  ; conversation_id : string option
  ; external_message_id : string option
  ; speaker : Keeper_chat_store.speaker
  ; user_row_origin : user_row_origin
  }

type terminal_delivery =
  | Assistant_reply of
      { content : string
      ; blocks : Keeper_chat_store.chat_block list option
      ; turn_ref : Ids.Turn_ref.t option
      }
  | Transport_failure of { content : string }
  | No_assistant_reply of { reason : no_assistant_reply_reason }

and no_assistant_reply_reason = Continuation_checkpoint

type terminal_result =
  { ok : bool
  ; poll_body : string
  ; delivery : terminal_delivery
  }

type phase =
  | Prepared
  | Accepted of { user_row_id : string }
  | Running of { user_row_id : string }
  | Terminal_pending of
      { terminal : terminal_result
      ; user_row_id : string
      }
  | Transcript_committed of
      { terminal : terminal_result
      ; transcript_row_id : string
      }
  | Final of
      { terminal : terminal_result
      ; transcript_row_id : string
      }

type t =
  { schema_version : int
  ; revision : int
  ; delivery_key : Identity.delivery_key
  ; payload : accepted_payload
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  }

type error =
  | Already_exists of string
  | Not_found of string
  | Invalid_keeper_name of string
  | Io_error of string
  | Decode_error of string
  | Identity_mismatch
  | Revision_conflict of
      { expected : int
      ; actual : int
      }
  | Invalid_transition of
      { expected : string
      ; actual : string
      }
  | Transcript_error of string

val error_to_string : error -> string
val phase_to_string : phase -> string

val prepare :
  base_path:string ->
  delivery_key:Identity.delivery_key ->
  payload:accepted_payload ->
  now:float ->
  (t, error) result

val mark_accepted :
  base_path:string ->
  expected_revision:int ->
  identity:t ->
  user_row_id:string ->
  now:float ->
  (t, error) result

val mark_running :
  base_path:string ->
  expected_revision:int ->
  identity:t ->
  now:float ->
  (t, error) result

val mark_terminal_pending :
  base_path:string ->
  expected_revision:int ->
  identity:t ->
  terminal:terminal_result ->
  now:float ->
  (t, error) result

val mark_transcript_committed :
  base_path:string ->
  expected_revision:int ->
  identity:t ->
  transcript_row_id:string ->
  now:float ->
  (t, error) result

val mark_final :
  base_path:string ->
  expected_revision:int ->
  identity:t ->
  now:float ->
  (t, error) result

val load :
  base_path:string ->
  keeper_name:string ->
  Identity.delivery_key ->
  (t, error) result

val list_for_keeper :
  base_path:string ->
  keeper_name:string ->
  (t list, error) result

(** Complete every durable non-final delivery without re-running inference.
    Recovery is lane-local: one malformed Keeper journal is reported without
    preventing other Keeper journals from converging. *)
type recovery_failure =
  { keeper_name : string
  ; delivery_ref : string
  ; error : error
  }

type recovery_report =
  { recovered : int
  ; already_final : int
  ; failures : recovery_failure list
  }

val recover_all : base_path:string -> now:float -> recovery_report

module For_testing : sig
  val to_yojson : t -> Yojson.Safe.t
  val of_yojson : Yojson.Safe.t -> (t, error) result
  val path :
    base_path:string ->
    keeper_name:string ->
    Identity.delivery_key ->
    (string, error) result
end
