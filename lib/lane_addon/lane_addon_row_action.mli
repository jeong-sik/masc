(** The host's verdict on each declared row action, judged against the action
    schema a worker advertises (RFC lane-row-offers-actions-filled-from-its-own-fields
    §2.3). Screens read the verdict instead of judging the schema again. *)

type human_member = { name : string; required : bool }
(** A member the operator fills: the chosen branch's members that are neither
    fixed nor read from the row. *)

type refusal =
  | Schema_shape_unsupported
      (** The action is neither one closed object nor an object [oneOf] of
          closed objects. *)
  | No_branch_accepts
  | Several_branches_accept of int list
  | Member_not_in_branch of string
      (** The single closed object does not declare this member. *)
  | Fixed_value_rejected of string
      (** The single closed object refuses the package's value for this member. *)

type verdict =
  | Offered of { branch : int option; human : human_member list }
      (** [branch] is the [oneOf] index of the one accepting branch, [None]
          for a single closed object. *)
  | Refused of refusal

val judge : tool_schema:Yojson.Safe.t -> Lane_addon_presentation.row_action -> verdict
(** [tool_schema] is the whole advertised lane action tool schema; the action
    is its [action] property. A branch accepts when it declares every fixed and
    row member and accepts every fixed value. Exactly one accepting branch is
    Offered. *)

val to_json : index:int -> verdict -> Yojson.Safe.t

val snapshot_fields :
  actions:Lane_addon_presentation.row_action list ->
  tool_schema:Yojson.Safe.t option ->
  (string * Yojson.Safe.t) list
(** The instance snapshot's [row_actions]: nothing for a package without row
    actions, [null] while no action schema is advertised, otherwise one verdict
    per action in declaration order. *)
