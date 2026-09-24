(** Removing every channel binding one Keeper holds, as one operator action.

    The TUI reads the bindings from the connector snapshot, arms once, and on
    the second press sends the server's conditional unbind for each binding
    with the Keeper's name. The server removes a binding only while it still
    names that Keeper, so a channel rebound to another Keeper in between is
    left alone and reported as such. *)

(** The key that arms and confirms unbind-all on a Keeper's Channels tab. *)
val unbind_all_key : string

(** One binding to remove: where it lives, which channel, and the Keeper the
    snapshot said owns it -- the condition the unbind is sent with. *)
type target = {
  connector_id : string;
  connector_name : string;
  channel_id : string;
  channel_name : string option;
  keeper_name : string;
}

(** What the server answered for one binding. *)
type outcome =
  | Removed
  | Rebound  (** HTTP 409: the channel now belongs to another Keeper. *)
  | Not_found of string
      (** HTTP 404, with the server's words: the store has no such binding, or
          the route does not know the connector. The status alone cannot tell
          which, so neither "already gone" nor a failure is claimed. *)
  | Failed of string  (** Any other refusal, or no answer, in its own words. *)

(** ["name (id)"] when the name directory knows the channel, otherwise
    ["id (name unknown)"]. Both parts are made single-line for the terminal. *)
val channel_label : channel_id:string -> channel_name:string option -> string

val target_label : target -> string

(** Every binding naming [keeper_name], across all transports, in snapshot
    order. *)
val targets : keeper_name:string -> Masc.Tui_decode.connector list -> target list

(** Display names of the transports whose binding store the server could not
    read ([binding_store_read_ok = false]). Their bindings are unknown, so
    {!targets} cannot include them and the prompts say so. *)
val unreadable_transports : Masc.Tui_decode.connector list -> string list

(** Reads a conditional-unbind reply by its HTTP status. [refusal] is the
    server's words, kept for a 404 and for any other non-success. *)
val outcome_of_status : status:int -> refusal:string -> outcome

(** One session log line per binding. *)
val outcome_line : target * outcome -> string

(** The results in the order they are reported: removed, kept, not found,
    failed. Failures come last so they are the lines a short event log keeps. *)
val report_order : (target * outcome) list -> (target * outcome) list

(** ["unbind all of <keeper>: N removed, M kept, K not found, F failed"],
    followed by the failed channels' labels. Short enough for an 80-column
    footer; "kept" is spelled out on each binding's own line. *)
val summary : keeper_name:string -> (target * outcome) list -> string

val any_failed : (target * outcome) list -> bool

(** The line shown after the first press, naming each channel it will remove
    and any transport left out because its binding list is unreadable. *)
val arm_prompt :
  keeper_name:string -> confirm_key:string -> unreadable:string list ->
  target list -> string

(** The line for a Keeper with no readable binding, naming unreadable
    transports so "none" is not claimed for them. *)
val nothing_to_unbind : keeper_name:string -> unreadable:string list -> string

(** The one key that takes the pause offer. It is not {!unbind_all_key}:
    on the Keeper list that key opens the runtime picker, and an operator
    who pauses a Keeper and then picks another runtime must not lose its
    channels. *)
val offer_key : string

(** An offer on screen: the Keeper, the bindings it named, and the count of
    frames presented when it was made. *)
type offer = {
  offer_keeper : string;
  offer_targets : target list;
  offered_at : int;
}

(** What one loop turn's input does to an offer. *)
type offer_reading =
  | Offer_waits  (** Nothing was read; the offer stays. *)
  | Offer_accepted  (** {!offer_key}, read after the offer was drawn. *)
  | Offer_dropped
      (** Any other input, or any key read before a frame after the offer
          was presented -- that key was typed for something else. The key
          keeps its own meaning. *)

val read_offer_input :
  offer -> frames_presented:int -> input_seen:bool -> key:string option ->
  offer_reading

(** The line shown after the operator paused or shut down a Keeper that still
    holds bindings: {!offer_key}, then the channels it would answer on again
    once it runs. Doing nothing is the default. *)
val offer_prompt :
  keeper_name:string -> unreadable:string list -> target list -> string

(** The line for a paused Keeper whose offer cannot take the next key here
    (another view, another Keeper selected, or another arm open). *)
val still_bound : keeper_name:string -> target list -> string

(** The line when the connector read an offer waited for failed. *)
val offer_read_failed : keeper_name:string -> detail:string -> string
