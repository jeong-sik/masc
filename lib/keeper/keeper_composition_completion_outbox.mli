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
    in [failures] and remain on disk. *)
