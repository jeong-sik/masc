(** Removing every channel binding one Keeper holds, as one operator action.

    The TUI reads the bindings from the connector snapshot, arms once, and on
    the second press sends the server's conditional unbind for each binding
    with the Keeper's name. The server removes a binding only while it still
    names that Keeper, so a channel rebound to another Keeper in between is
    left alone and reported as such. *)

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
  | Already_unbound  (** HTTP 404: no binding for the channel remains. *)
  | Failed of string  (** Any other refusal, or no answer, in its own words. *)

(** ["name (id)"] when the name directory knows the channel, otherwise
    ["id (name unknown)"]. Both parts are made single-line for the terminal. *)
val channel_label : channel_id:string -> channel_name:string option -> string

val target_label : target -> string

(** Every binding naming [keeper_name], across all transports, in snapshot
    order. *)
val targets : keeper_name:string -> Masc.Tui_decode.connector list -> target list

(** Reads a conditional-unbind reply by its HTTP status. [refusal] is the text
    kept for a status that is neither success, 404, nor 409. *)
val outcome_of_status : status:int -> refusal:string -> outcome

(** One Recent Events line per binding. *)
val outcome_line : target * outcome -> string

(** ["unbind all of <keeper>: N removed, M skipped, K failed"]. *)
val summary : keeper_name:string -> (target * outcome) list -> string

val any_failed : (target * outcome) list -> bool

(** The line shown after the first press, naming each channel it will remove. *)
val arm_prompt : keeper_name:string -> confirm_key:string -> target list -> string

(** The line shown after the operator paused or shut down a Keeper that still
    holds bindings: the channels it would answer on again once it runs, and
    the one key that removes them. Doing nothing is the default. *)
val offer_prompt : keeper_name:string -> confirm_key:string -> target list -> string
