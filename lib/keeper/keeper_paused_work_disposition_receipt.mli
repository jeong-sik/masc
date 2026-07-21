(** Durable typed intent receipts for explicit paused-work disposition. *)

type continuation_binding =
  | Routed of Keeper_continuation_channel.t
  | No_channel

type transfer_owner =
  { from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  ; target_generation : int
  ; source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; settled_at : float
  ; continuation_binding : continuation_binding
  }

type operation =
  | Resume_owner
  | Transfer_owner of transfer_owner

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

val continuation_binding_of_source :
  Keeper_event_queue.stimulus -> continuation_binding
(** Extract the exact routed channel carried by channel-bearing source kinds;
    all other typed stimuli use [No_channel]. *)

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
