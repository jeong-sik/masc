module Operation_id : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool

  val for_event : keeper_key:string -> event_identity:string -> t

  val for_continuation
    :  parent:t
    -> continuation_ref:string
    -> t

  val for_keeper_message
    :  causing_operation:t
    -> tool_call_id:string
    -> ordinal:int
    -> target_keeper:string
    -> t

  val for_autonomous : keeper_key:string -> candidate_identity:string -> t
end

module Delivery_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool

  val derive
    :  operation_id:Operation_id.t
    -> ordinal:int
    -> destination_ref:string
    -> payload_ref:string
    -> t
end
