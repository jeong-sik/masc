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

type route =
  | Deliver of Keeper_world_observation_board_signal.wake_reason
  | Judge_discoverable
  | Ignore

val classify
  :  visibility:Board.visibility
  -> Board_dispatch.board_signal
  -> (t, classification_error) result
(** Exact explicit address wins. Otherwise comments and reactions are scoped
    to structural thread participants, while a newly-created unaddressed post
    is discoverable.

    Fail-closed address/visibility contract (validated through the typed
    {!Board.audience} write boundary, surfaced as [Invalid_board_audience]):
    - an unsupported [@@name] selector or a malformed [@target] token rejects
      the whole signal, even when valid [@keeper] targets are mixed in (no
      partial routing);
    - [@@all] on a [Direct] post is rejected: [Direct] means "mentioned
      agents only", so a fleet broadcast would contradict the visibility the
      author chose.  [@@all] on [Public]/[Unlisted]/[Internal] classifies as
      {!Broadcast};
    - a [Direct] post-creation without any explicit address is rejected. *)

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
