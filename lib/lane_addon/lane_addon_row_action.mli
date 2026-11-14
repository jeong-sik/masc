(** The host's verdict on each declared row action, judged against the action
    schema a worker advertises (RFC lane-row-offers-actions-filled-from-its-own-fields
    §2.3). Screens read the verdict instead of judging the schema again. *)

type human_member = { name : string; required : bool }
(** A member the operator fills: the chosen branch's members that are neither
    fixed nor read from the row. *)

type refusal =
  | Schema_shape_unsupported
      (** The action is neither one closed object nor an object [oneOf] of
          closed objects, or one of those nodes carries a keyword besides
          their structure, [title] and [description]. *)
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

val judge :
  tool_name:string -> tool_schema:Yojson.Safe.t -> Lane_addon_presentation.row_action -> verdict
(** [tool_schema] is the whole advertised lane action tool schema; the action
    is its [action] property. A branch accepts when it declares every fixed and
    row member and accepts every fixed value. Fixed values are checked under
    [tool_name], the name a send is checked under. Exactly one accepting branch
    is Offered. *)

val to_json : index:int -> verdict -> Yojson.Safe.t

val snapshot_fields :
  actions:Lane_addon_presentation.row_action list ->
  tool:(string * Yojson.Safe.t) option ->
  (string * Yojson.Safe.t) list
(** The instance snapshot's [row_actions]: nothing for a package without row
    actions, [null] while no action tool name and schema are advertised,
    otherwise one verdict per action in declaration order. [tool] is the action
    tool's name and its advertised schema. *)

val snapshot_of_json : Yojson.Safe.t -> (verdict list option, string) result
(** Reads back the [row_actions] value {!snapshot_fields} writes: [null] is
    [None], a list holds one verdict per declared row action. Members may come
    in any order. Unknown shapes or reasons, indices out of declaration order
    and negative alternative positions are refused. *)

(** Why one row cannot fill a row action. The screen writes the words. *)
type unfilled =
  | Not_offered of refusal
      (** The host refused the action, or the schema has no alternative where
          the verdict says. *)
  | Row_value_absent of { member : string; path : string list }
  | Row_value_wrong_shape of { member : string; path : string list }
      (** A step on [path] is not an object, or the value is [null]. *)
  | Row_value_rejected of { member : string; detail : string }
      (** The row has the value, and the member's schema refuses it. *)

type filled = { branch : int option; locked : (string * Yojson.Safe.t) list }
(** The alternative to open and the members nobody may change: the package's
    [fixed] values, then the row's values, in declaration order. *)

val fill :
  tool_name:string -> tool_schema:Yojson.Safe.t -> verdict ->
  Lane_addon_presentation.row_action -> Yojson.Safe.t -> (filled, unfilled list) result
(** Reads each [from_row] member from a row's fields and checks it against
    that member's schema in the offered alternative of [tool_schema], under
    [tool_name] as a send checks it. Lists every member the row cannot fill. *)
