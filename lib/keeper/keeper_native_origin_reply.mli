(** Exact native destination retained by an autonomous continuation. The type
    admits only Telegram and iMessage routes with a concrete send destination. *)
type t
val of_continuation :
  ?imessage_destination:string -> Keeper_continuation_channel.t -> (t, string) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
val connector : t -> string
val channel_id : t -> string
(** Original conversation binding key. *)
val destination_id : t -> string
(** Actual send destination; iMessage self-chat may differ from the origin. *)
val matches_continuation : t -> Keeper_continuation_channel.t -> bool
val surface : t -> Surface_ref.t
val check_binding : keeper_name:string -> t -> (unit, string) result
(** Fresh authoritative binding read, including on approval replay. *)
val send :
  ?telegram_post:Telegram_rest_client.post ->
  ?imessage_send:(chat_guid:string -> content:string -> (unit, string) result) ->
  clock:[> float Eio.Time.clock_ty] Eio.Resource.t ->
  t -> content:string -> (unit, string) result
(** Transport errors retain uncertainty; the caller must not blindly replay an
    external effect after failure. Telegram retains bot/topic/reply coordinates.
    iMessage uses the destination already resolved from the configured mode. *)
