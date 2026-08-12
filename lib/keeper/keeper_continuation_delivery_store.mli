(** Producer-side durable obligation store for autonomous continuation replies.

    The Keeper chat operation store remains the chat-delivery SSOT. This store covers the
    different authority boundary where a generic Keeper event source has
    already produced a reply but its final surface projection is not terminal.
    One file owns one deterministic intent id; there is no second copy of a
    chat operation. *)

type publication =
  | Not_published
  | Published_indeterminate

type error =
  | Invalid_keeper_name of string
  | Invalid_intent_id of string
  | Not_found of string
  | Read_failed of string
  | Decode_failed of string
  | Identity_conflict of string
  | Invalid_state_transition of
      { from_state : string
      ; to_state : string
      }
  | Persistence_failed of
      { publication : publication
      ; detail : string
      }

val error_to_string : error -> string

type persist_outcome =
  | Created
  | Advanced
  | Already_current

val persist :
  config:Workspace.config ->
  Keeper_continuation_delivery_intent.t ->
  (persist_outcome, error) result
(** Atomically create or monotonically advance one intent.  Exact replay is
    idempotent.  Changed immutable content under the same id, skipped states,
    and any transition out of a terminal state fail closed. *)

val load :
  config:Workspace.config ->
  keeper_name:string ->
  intent_id:Keeper_continuation_delivery_intent.Intent_id.t ->
  (Keeper_continuation_delivery_intent.t, error) result

type record_failure =
  { path : string
  ; detail : string
  }

type inventory =
  { intents : Keeper_continuation_delivery_intent.t list
  ; record_failures : record_failure list
  }

val inventory :
  config:Workspace.config -> keeper_name:string -> (inventory, error) result
(** Return every valid obligation and report malformed peer records beside
    them.  One corrupt record never disappears as an empty inventory. *)

val cleanup_staging_for_startup :
  config:Workspace.config ->
  keeper_name:string ->
  (Fs_compat.atomic_orphan_cleanup_report, error) result

module For_testing : sig
  val active_directory :
    config:Workspace.config -> keeper_name:string -> (string, error) result

  val staging_directory :
    config:Workspace.config -> keeper_name:string -> (string, error) result
end
