(** Default vs live override-field detail builder + 5 typed
    matchers for keeper status surfaces.

    Used by [live_override_details] (still in
    [Keeper_status_bridge]) to compare a keeper's
    [keeper_profile_defaults] against the live [keeper_meta] field
    by field, producing a JSON-rendered list of overrides for the
    operator dashboard.

    Each matcher applies the same shape: take ~field name + default
    + live, emit a [override_field_detail] iff the two differ.
    Variants per type: [maybe_string_override] (optional string
    with an optional normalizer), [maybe_bool_override] (optional
    bool), [maybe_string_list_override] (optional list),
    [nonempty_string_list_override] (non-empty list — empty default
    means no preference, not a difference), [maybe_string_option_
    override] (both default and live are options).

    Pure builders — no parent state, no I/O. Verbatim extract from
    [Keeper_status_bridge]; [string_list_to_json] is a 1-line local
    duplicate because the parent's copy is in flight on a different
    extract path and this 1-line helper isn't worth a third sibling. *)

let string_list_to_json = Json_util.json_string_list

type override_field_detail =
  { field : string
  ; default_value : Yojson.Safe.t
  ; live_value : Yojson.Safe.t
  }

let override_field field ~default_value ~live_value =
  { field; default_value; live_value }

let maybe_string_override field ?(normalize = fun value -> value) default live acc =
  let default = Option.map normalize default in
  match default with
  | Some value when value <> live ->
    override_field field ~default_value:(`String value) ~live_value:(`String live) :: acc
  | _ -> acc
;;

let maybe_bool_override field default live acc =
  match default with
  | Some value when value <> live ->
    override_field field ~default_value:(`Bool value) ~live_value:(`Bool live) :: acc
  | _ -> acc
;;

let maybe_string_list_override field default live acc =
  match default with
  | Some authored when authored <> live ->
    override_field
      field
      ~default_value:(string_list_to_json authored)
      ~live_value:(string_list_to_json live)
    :: acc
  | _ -> acc
;;

let nonempty_string_list_override field default live acc =
  if default <> [] && default <> live
  then
    override_field
      field
      ~default_value:(string_list_to_json default)
      ~live_value:(string_list_to_json live)
    :: acc
  else acc
;;

let maybe_string_option_override field default live acc =
  match default, live with
  | Some authored, Some active when authored <> active ->
    override_field field ~default_value:(`String authored) ~live_value:(`String active)
    :: acc
  | _ -> acc
;;
