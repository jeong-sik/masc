(** Cp_orchestra_helpers — JSON helpers and graph primitives for CP orchestra.

    Provides node/edge/signal builder functions and JSON extraction utilities.

    @since God file decomposition — extracted from command_plane_orchestra.ml *)

module U = Yojson.Safe.Util

let trim_to_option = Dashboard_utils.trim_to_option

let first_some = Dashboard_utils.first_some

let string_opt json key =
  match U.member key json with
  | `String value -> trim_to_option value
  | _ -> None

let int_opt json key =
  match U.member key json with
  | `Int value -> Some value
  | `Intlit value -> (int_of_string_opt (value))
  | `Float value -> Some (int_of_float value)
  | _ -> None

let float_opt json key =
  match U.member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit value -> (try Some (float_of_string value) with Failure _ -> None)
  | _ -> None

let bool_opt json key =
  match U.member key json with
  | `Bool value -> Some value
  | _ -> None

let list_member json key =
  match U.member key json with
  | `List rows -> rows
  | _ -> []

let assoc_or_empty json key =
  match U.member key json with
  | `Assoc _ as value -> value
  | _ -> `Assoc []

let json_string_option = function
  | Some value -> `String value
  | None -> `Null

let json_int_option = function
  | Some value -> `Int value
  | None -> `Null

let json_float_option = function
  | Some value -> `Float value
  | None -> `Null

let json_params fields = `Assoc fields

let fact label value =
  `Assoc [ ("label", `String label); ("value", `String value) ]

let node ?subtitle ?status ?pulse ?parent_id ?lane_id ?link_tab ?link_surface
    ?(link_params = `Assoc []) ~id ~kind ~label ~tone ~provenance ~visual_class
    ~glyph ~facts () =
  `Assoc
    [
      ("id", `String id);
      ("kind", `String kind);
      ("label", `String label);
      ("subtitle", json_string_option subtitle);
      ("status", json_string_option status);
      ("tone", `String tone);
      ("pulse", json_string_option pulse);
      ("provenance", `String provenance);
      ("visual_class", `String visual_class);
      ("glyph", `String glyph);
      ("parent_id", json_string_option parent_id);
      ("lane_id", json_string_option lane_id);
      ("link_tab", json_string_option link_tab);
      ("link_surface", json_string_option link_surface);
      ("link_params", link_params);
      ("facts", `List facts);
    ]

let edge ?label ?(tone = "ok") ?(provenance = "derived") ?(animated = false)
    ~id ~source ~target ~kind () =
  `Assoc
    [
      ("id", `String id);
      ("source", `String source);
      ("target", `String target);
      ("kind", `String kind);
      ("label", json_string_option label);
      ("tone", `String tone);
      ("provenance", `String provenance);
      ("animated", `Bool animated);
    ]

let signal ?detail ?source_id ?target_id ?suggested_surface
    ?(suggested_params = `Assoc []) ?(provenance = "derived") ~id ~kind ~label
    ~tone () =
  `Assoc
    [
      ("id", `String id);
      ("kind", `String kind);
      ("label", `String label);
      ("detail", json_string_option detail);
      ("tone", `String tone);
      ("provenance", `String provenance);
      ("source_id", json_string_option source_id);
      ("target_id", json_string_option target_id);
      ("suggested_surface", json_string_option suggested_surface);
      ("suggested_params", suggested_params);
    ]

let status_tone = function
  | "failed" | "error" | "cancelled" | "offline" | "stalled" | "bad" -> "bad"
  | "paused" | "interrupted" | "warn" | "waiting" | "degraded" -> "warn"
  | _ -> "ok"

let pulse_of_tone = function
  | "bad" -> Some "blink"
  | "warn" -> Some "pulse"
  | _ -> Some "steady"
