(** Request-local recall from recorded original messages in an admitted
    Discord wake. Every admitted source and its reply route must agree. *)

type request

val select
  :  keeper_id:string
  -> route:Keeper_continuation_channel.t
  -> stimuli:Keeper_event_queue.stimulus list
  -> recorded:(string * Keeper_external_attention.item) list
  -> request option

val render
  :  keepers_dir:string
  -> keeper_id:string
  -> request
  -> (string option, string) result
(** Rank an exact-scope snapshot with the admitted message text. The text
    contains only matching fact claims and is bounded for prompt use. *)

val for_turn
  :  base_path:string
  -> keeper_id:string
  -> batch:Keeper_heartbeat_source_batch.t
  -> route:Keeper_continuation_channel.t
  -> (string option, string) result
(** Reuse the original-message rows read at intake and confirm that the
    exact selections still stand before reading Memory. *)
