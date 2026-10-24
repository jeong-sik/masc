(** Durable prepared request ownership before Telegram can enter a per-Keeper
    admission store. The operation ID is the bot/generation/update identity
    produced by Telegram_poll_custody; the hash in the filename is only a path
    key, never an effect receipt. The complete canonical request is compared. *)
type error = Invalid_claim | Conflicting_claim | Storage_failed of string
val error_to_string : error -> string
val ensure : root:string -> operation_id:string -> identity:Yojson.Safe.t -> (unit, error) result
(** Persist before dispatch; an existing claim must match the whole prepared
    recipient/payload/delivery identity and establish file+parent sync again. *)
val ensure_unclaimed : root:string -> operation_id:string -> (unit, error) result
(** An update already claimed for delivery cannot turn into an ignored update
    after a binding/payload change. Missing claims are not cached. *)
module For_testing : sig
  val ensure_with_io :
    write:(string -> string -> (unit, string) result) ->
    sync:(string -> (unit, string) result) ->
    root:string -> operation_id:string -> identity:Yojson.Safe.t -> (unit, error) result
end
