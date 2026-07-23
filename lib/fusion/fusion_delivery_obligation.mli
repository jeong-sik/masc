(** Durable producer-specific delivery obligation for Fusion.

    {!Keeper_msg_async} remains the sole request lifecycle and terminal truth.
    This module stores only the immutable information that its generic record
    cannot know: the accepted Fusion request and originating continuation
    channel needed to project that terminal after a restart. *)

module Request_id = Keeper_chat_delivery_identity.Request_id

type accepted_payload =
  { keeper_name : string
  ; submitted_by : string
  ; prompt : string
  ; preset : string
  ; web_tools : bool
  ; topology : Fusion_types.fusion_topology
  ; channel : Keeper_continuation_channel.t
  }

type t = private
  { schema_version : int
  ; request_id : Request_id.t
  ; payload : accepted_payload
  ; accepted_at : float
  }

type prepare_outcome =
  | Prepared of t
  | Already_present of t

type publication =
  | Not_published
  | Published_indeterminate

type error =
  | Invalid_base_path of string
  | Invalid_keeper_name of string
  | Invalid_request_id of string
  | Invalid_payload of string
  | Not_found of string
  | Read_failed of string
  | Decode_failed of string
  | Identity_conflict of string
  | Persistence_failed of
      { publication : publication
      ; detail : string
      }
  | Removal_failed of
      { removed : bool
      ; detail : string
      }

val error_to_string : error -> string

val prepare :
  base_path:string ->
  request_id:Request_id.t ->
  payload:accepted_payload ->
  accepted_at:float ->
  (prepare_outcome, error) result
(** Persist acceptance before the worker starts. An exact replay returns
    [Already_present]; the same request id with different immutable payload is
    an explicit [Identity_conflict]. *)

val load : base_path:string -> request_id:Request_id.t -> (t, error) result

val remove_delivered : base_path:string -> identity:t -> (unit, error) result
(** Remove only the exact accepted record after its terminal projection has
    succeeded. A post-unlink directory-fsync failure remains explicit; the
    projected effects are idempotent, so either possible restart view is safe.
    Repeating removal with the same in-memory identity after the file is gone
    is idempotent. *)

type record_failure =
  { path : string
  ; detail : string
  }

type inventory =
  { obligations : t list
  ; record_failures : record_failure list
  }

val inventory : base_path:string -> (inventory, error) result
(** Inspect the active obligation directory without repairing or dropping
    malformed records. One bad record is reported beside recoverable peers. *)

val cleanup_staging_for_startup :
  base_path:string -> (Fs_compat.atomic_orphan_cleanup_report, error) result
(** Reconcile crash-left atomic staging files before producer fibers start.
    Empty orphans are deleted and non-empty orphans are preserved by the shared
    filesystem recovery policy. The caller must hold startup ownership so no
    matching atomic write can be in flight. *)

module For_testing : sig
  val active_directory : base_path:string -> (string, error) result
  val staging_directory : base_path:string -> (string, error) result
end
