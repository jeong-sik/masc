(** Durable typed intent receipts for explicit paused-work disposition. *)

type operation = Resume_owner

type t =
  { keeper_name : string
  ; expected_trace_id : Keeper_id.Trace_id.t
  ; expected_generation : int
  ; operator_operation_id : string
  ; requested_at : float
  ; operation : operation
  }

type save_result =
  | Created
  | Existing of t

type keeper_lock

val equal : t -> t -> bool

val load :
  Workspace.config ->
  keeper_name:string ->
  operator_operation_id:string ->
  (t option, string) result

val with_keeper_lock :
  Workspace.config ->
  keeper_name:string ->
  (keeper_lock -> 'a) ->
  ('a, string) result
(** Serialize every disposition operation for one Keeper across processes. *)

val save_if_absent :
  keeper_lock -> Workspace.config -> t -> (save_result, string) result
(** Persist [t] with a strict durable atomic write. An existing operation ID is
    returned for exact replay or conflict handling and is never overwritten. *)
