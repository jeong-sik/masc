(** Signal-centric Board routing authority for Keeper lanes. *)

type t =
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast
  | Thread_participants
  | Discoverable
(** Closed audience sum from the mixed-workload operation contract. Only
    [Discoverable] may enter semantic attention judgment. *)

type classification_error =
  | Invalid_board_audience of Board.board_error
  | Invalid_board_target of string
  | Audience_not_recorded

type route =
  | Deliver of Keeper_world_observation_board_signal.wake_reason
  | Judge_discoverable
  | Ignore

val of_post : Board.post -> (t, classification_error) result
(** The audience the write boundary recorded with the post. A post that
    records none is [Error Audience_not_recorded]: its title and body are not
    read for an address. *)

val of_comment_text : content:string -> (t, classification_error) result
(** A comment records no audience, so it is read from its own content. An exact
    explicit address wins, otherwise the comment is scoped to
    [Thread_participants]. The post a comment belongs to is not part of it.
    An unsupported [@@name] selector is [Invalid_board_audience]. *)

val of_board_audience : Board.audience -> (t, classification_error) result
(** Project generic Board identities into canonical Keeper lane identities.
    This is the only MASC-specific step; Board remains Keeper-independent. *)

val route_for_keeper
  :  audience:t
  -> meta:Keeper_meta_contract.keeper_meta
  -> signal:Board_dispatch.board_signal
  -> route Keeper_world_observation_board_signal.board_read

val label : t -> string
val classification_error_to_string : classification_error -> string
