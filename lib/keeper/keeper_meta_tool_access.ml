(** Keeper meta tool-access contract and JSON helpers.

    Included by [Keeper_meta_contract] so [Keeper_types.*] keeps the same
    public API while tool preset/access policy is isolated from the broader
    keeper meta runtime contract. *)

open Keeper_types_profile

type tool_preset =
  | Minimal
  | Social
  | Messaging
  | Dispatch
  | Coding
  | Research
  | Delivery
  | Full

type tool_access =
  | Preset of
      { preset : tool_preset
      ; also_allow : string list
      }
  | Custom of string list

let tool_names_include_board name_list =
  List.exists
    (fun name ->
       match Tool_name.of_string name with
       | Some tool -> Tool_name.is_board tool
       | None -> false)
    name_list
;;

let tool_access_default_room_signal_prompt_enabled ~default = function
  | Preset { preset = Minimal; also_allow } ->
    default || tool_names_include_board also_allow
  | Preset _ -> true
  | Custom tool_names -> tool_names_include_board tool_names
;;

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

let legacy_keeper_internal_tool_names =
  (* Keep legacy masc coordination defaults explicit in
     [legacy_session_min_tool_names]; new [masc_*] internal tools should not
     silently expand missing [tool_access] migrations. *)
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal
  |> List.filter (fun name -> not (String.starts_with ~prefix:"masc_" name))
;;

let legacy_session_min_tool_names =
  (* Legacy keepers historically received canonical masc_* coordination tools,
     not the SDK alias-heavy Session_min surface. Keep this compatibility list
     explicit so missing tool_access migration remains stable after tier removal. *)
  List.map
    Tool_name.Masc.to_string
    Tool_name.Masc.
      [ Status; Tasks; Claim_next; Plan_set_task; Transition; Add_task; Broadcast ]
;;

let migrate_legacy_restricted_tools names =
  Custom (normalize_tool_names (legacy_keeper_internal_tool_names @ names))
;;

let tool_preset_to_string = function
  | Minimal -> "minimal"
  | Social -> "social"
  | Messaging -> "messaging"
  | Dispatch -> "dispatch"
  | Coding -> "coding"
  | Research -> "research"
  | Delivery -> "delivery"
  | Full -> "full"
;;

(** Issue #8430: schema enums for [tool_preset] in [keeper_schema.ml]
    used to be hand-rolled and dropped [Social] and [Delivery] — a live
    correctness bug since callers reading the schema could not discover
    those values exist. Same Variant SSOT class as #8354 / #8392. All
    constructors are nullary so the simple [List.map] trick works.
    Adding an 8th constructor will fail compilation in
    [tool_preset_to_string] and in the witness test. *)
let all_tool_presets =
  [ Minimal; Social; Messaging; Dispatch; Coding; Research; Delivery; Full ]
;;

let valid_tool_preset_strings = List.map tool_preset_to_string all_tool_presets

let tool_preset_of_string raw =
  match String.trim (String.lowercase_ascii raw) with
  | "minimal" -> Some Minimal
  | "social" -> Some Social
  | "messaging" -> Some Messaging
  | "dispatch" -> Some Dispatch
  | "coding" -> Some Coding
  | "research" -> Some Research
  | "delivery" -> Some Delivery
  | "full" -> Some Full
  | _ -> None
;;

let normalize_tool_access = function
  | Preset { preset; also_allow } ->
    Preset { preset; also_allow = normalize_tool_names also_allow }
  | Custom names -> Custom (normalize_tool_names names)
;;

let tool_access_preset = function
  | Preset { preset; _ } -> Some preset
  | Custom _ -> None
;;

let tool_access_custom_allowlist = function
  | Preset _ -> None
  | Custom names -> Some names
;;

let tool_access_also_allowlist = function
  | Preset { also_allow; _ } -> also_allow
  | Custom _ -> []
;;

let tool_access_to_json access =
  match normalize_tool_access access with
  | Preset { preset; also_allow } ->
    `Assoc
      [ "kind", `String "preset"
      ; "preset", `String (tool_preset_to_string preset)
      ; "also_allow", `List (List.map (fun s -> `String s) also_allow)
      ]
  | Custom names ->
    `Assoc
      [ "kind", `String "custom"; "tools", `List (List.map (fun s -> `String s) names) ]
;;

let json_member_present key (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> List.mem_assoc key fields
  | _ -> false
;;

let string_list_field_result ?label ~field_name (json : Yojson.Safe.t) =
  let label = Option.value ~default:field_name label in
  match Yojson.Safe.Util.member field_name json with
  | `List items ->
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | _ :: _ -> Error (Printf.sprintf "keeper %s[%d] must be a string" label index)
    in
    collect [] 0 items
  | `Null -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
  | _ -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
;;

let string_list_field_opt_result ?label ~field_name (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member field_name json with
  | `Null -> Ok []
  | _ -> string_list_field_result ?label ~field_name json
;;

let default_tool_access_of_meta_json () =
  migrate_legacy_restricted_tools legacy_session_min_tool_names
;;

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "tool_access" json with
  | `Null -> Ok (default_tool_access_of_meta_json ())
  | `Assoc _ as access_json ->
    let kind =
      Yojson.Safe.Util.member "kind" access_json |> Yojson.Safe.Util.to_string_option
    in
    (match kind with
     | Some "preset" ->
       let preset_raw =
         Yojson.Safe.Util.member "preset" access_json |> Yojson.Safe.Util.to_string_option
       in
       (match preset_raw with
        | None -> Error "keeper tool_access.preset required"
        | Some raw ->
          (match tool_preset_of_string raw with
           | None -> Error (Printf.sprintf "invalid keeper tool_access.preset: %s" raw)
           | Some preset ->
             (match
                string_list_field_opt_result
                  ~field_name:"also_allow"
                  ~label:"tool_access.also_allow"
                  access_json
              with
              | Ok also_allow ->
                Ok (normalize_tool_access (Preset { preset; also_allow }))
              | Error msg -> Error msg)))
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools -> Ok (normalize_tool_access (Custom tools))
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None -> Error "keeper tool_access.kind required")
  | _ -> Error "keeper tool_access must be an object"
;;
