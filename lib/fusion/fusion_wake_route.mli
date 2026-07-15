(** Durable upper adapter.

    [masc_fusion] is asynchronous: the keeper turn that starts a deliberation
    ends long before the [Fusion_completed] wake fires, so the originating
    connector conversation (RFC-0320 [Keeper_continuation_channel]) must be
    carried across that gap.  The pure run registry
    remains keeper-free; the generic outbox is projected here. *)

type error
type delivery_receipt = Delivered | Already_delivered
type drain_report = { delivered : int; failures : error list }

val error_to_string : error -> string
val validate_registered_address : string -> (unit, error) result
val register :
  operation_id:string -> owner:string -> channel:Keeper_continuation_channel.t ->
  (Fusion_completion_outbox.register_receipt, error) result

val queue_completion :
  operation_id:string -> ok:bool -> content:string -> evidence_ref:string option ->
  (Fusion_completion_outbox.completion_receipt, error) result

val complete_and_deliver :
  base_dir:string -> operation_id:string -> ok:bool -> content:string ->
  evidence_ref:string option -> (delivery_receipt, error) result
val drain_all : base_dir:string -> drain_report
