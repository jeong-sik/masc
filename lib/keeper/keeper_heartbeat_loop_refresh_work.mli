(** Work-as-heartbeat refresher for keeper heartbeat loop state. *)

val refresh_work_as_heartbeat :
  ctx:_ Keeper_types_profile.context ->
  meta_after_proactive:Keeper_meta_contract.keeper_meta ->
  proactive_warmup_elapsed:bool ->
  work_as_hb:(unit -> bool) ->
  consecutive_failures:int ref ->
  unit
(** Run the configured workspace heartbeat after an eligible turn. A
    successful heartbeat resets [consecutive_failures]; failure leaves it
    unchanged. *)
