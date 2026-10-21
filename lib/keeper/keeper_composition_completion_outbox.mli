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
    released result waiting attempt and its immutable producer identity.
    The canonical re-read and obligation removal share the request's store
    transition lock, so a concurrent refusal cannot lose its new obligation.
    It emits no composition terminal and grants no job replay permission. *)


type report =
  { inspected : int
  ; waiting : int
  ; delivered : int
  ; failures : (string * error) list
  }

type pending = private { base_path : string; keeper_name : string; request_id : string }
type discovery = private { entries : pending list; failures : (string * error) list }
val discover : base_path:string -> (discovery, error) result
(** Read and validate the original pending identities in directory order.
    Captures the canonical base path and recipient, not terminal or execution
    authority. Missing records carry no work; malformed records remain failures
    labeled by pending filename, not an unverified decoded request identity. *)

type record_outcome = Retired | Waiting | Delivered
val recover :
  pending ->
  deliver:(completion:Keeper_tool_execution_journal.completion_observation ->
    composition_tool:string -> Keeper_msg_async.entry -> (unit, string) result) ->
  (record_outcome, error) result
(** Reread this original obligation and reject a changed request/recipient before
    loading current canonical terminal proof and using the same delivery/ACK
    path as [flush]. The delivery callback receives the same original completion
    observation, so result hints do not repeat disposition reads. A removed
    obligation is retired; a pending hint cannot
    borrow another owner's obligation or authorize replay. *)

val flush :
  base_path:string ->
  deliver:(completion:Keeper_tool_execution_journal.completion_observation ->
    composition_tool:string -> Keeper_msg_async.entry -> (unit, string) result) ->
  (report, error) result
(** Reconcile only this pending partition. Read exact canonical terminal
    proof before delivery; never execute or restart a request worker. Active
    requests keep their obligation. Malformed/unreadable records stay visible
    in [failures] and remain on disk. Canonically released result waiting
    attempts retire their attempt notification without calling [deliver]. *)

module For_testing : sig
  val acknowledge_waiting :
    after_waiting_read:(unit -> unit) ->
    base_path:string -> keeper_name:string -> request_id:string -> composition_tool:string ->
    (unit, error) result
  (** Pause the production acknowledgement after its locked status check and
      before removal, to exercise contention with canonical status writers. *)
end
