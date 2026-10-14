(** A completion delivery obligation recorded before an async worker starts.
    The canonical request record owns the result and producer context; this
    outbox retains only the exact request and recipient identity. *)

type error =
  | Storage_failed of string
  | Invalid_obligation of string
  | Request_unavailable of Keeper_msg_async.load_result
  | Canonical_result_unavailable of Keeper_msg_async.canonical_terminal_error

val error_to_string : error -> string

val prepare :
  base_path:string -> keeper_name:string -> request_id:string -> composition_tool:string ->
  (unit, error) result
(** Called from [on_accepted]. Rejects a non-queued request or a producer/owner
    mismatch. A failed durable write prevents the worker from starting. *)

val acknowledge : base_path:string -> keeper_name:string -> request_id:string -> (unit, error) result
(** Retire only after durable delivery succeeds. A failed removal leaves the
    same request identity available for reconciliation. *)

val acknowledge_waiting :
  base_path:string -> keeper_name:string -> request_id:string -> composition_tool:string ->
  (unit, error) result
(** Retire a notification obligation only after exact canonical proof of a
    released owned-job waiting attempt and its immutable producer identity.
    It emits no composition terminal and grants no job replay permission. *)

val prepare_terminal :
  base_path:string -> keeper_name:string -> request_id:string -> (unit, error) result
(** Record a delivery obligation for an exact canonical
    [Waiting_for_owned_jobs] terminal owned by [keeper_name] before a
    permanent refusal supersedes it with a failure terminal. While the record
    remains waiting, [flush] retires the obligation without delivering; once
    the canonical record settles, [flush] delivers the typed failure through
    the same path as an ordinary completion. The same identity is
    idempotent. *)

type report =
  { inspected : int
  ; waiting : int
  ; delivered : int
  ; failures : (string * error) list
  }

val flush :
  base_path:string ->
  deliver:(composition_tool:string -> Keeper_msg_async.entry -> (unit, string) result) ->
  (report, error) result
(** Reconcile only this pending partition. Read exact canonical terminal
    proof before delivery; never execute or restart a request worker. Active
    requests keep their obligation. Malformed/unreadable records stay visible
    in [failures] and remain on disk. Canonically released owned-job waiting
    attempts retire their attempt notification without calling [deliver]. *)
