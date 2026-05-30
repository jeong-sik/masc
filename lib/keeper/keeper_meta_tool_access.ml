(** Keeper meta tool-access contract and JSON helpers.

    Included by [Keeper_meta_contract] so [Keeper_types.*] keeps the same
    public API while tool preset/access policy is isolated from the broader
    keeper meta runtime contract. *)

open Keeper_types_profile

type tool_access = All | Custom of string list

let tool_names_include_board name_list =
  List.exists
    (fun name ->
       match Tool_name.of_string name with
       | Some tool -> Tool_name.is_board tool
       | None -> false)
    name_list
;;

let tool_access_default_room_signal_prompt_enabled ~default = function
  | All -> default
  | Custom tool_names -> default || tool_names_include_board tool_names
;;

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

let write_tools =
  [ "tool_edit_file"; "tool_write_file"; "tool_execute" ]
;;

let legacy_keeper_internal_tool_names =
  (* Keep legacy masc coordination defaults explicit in
     [legacy_session_min_tool_names]; new [masc_*] internal tools should not
     silently expand missing [tool_access] migrations.
     Write tools are excluded so that keepers without explicit [tool_access]
     cannot claim write-intent tasks.  Keepers that need write access must
     use [Custom] with explicit write tool names. *)
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal
  |> List.filter (fun name ->
         not (String.starts_with ~prefix:"masc_" name)
         && not (List.exists (String.equal name) write_tools))
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

let normalize_tool_access = function
  | All -> All
  | Custom names -> Custom (normalize_tool_names names)
;;

let tool_access_custom_allowlist = function
  | All -> []
  | Custom names -> names
;;

let tool_access_to_json = function
  | All ->
      `Assoc
        [ "kind", `String "custom"; "tools", `List [] ]
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
  match Json_util.assoc_member_opt field_name json with
  | Some (`List items) ->
    let rec collect acc index = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> collect (value :: acc) (index + 1) rest
      | bad :: _ ->
        Error
          (Printf.sprintf "keeper %s[%d] must be a string (received %s)" label
             index (Json_util.kind_name bad))
    in
    collect [] 0 items
  | Some `Null | None -> Error (Printf.sprintf "keeper %s must be an array of strings" label)
  | Some other ->
    Error
      (Printf.sprintf "keeper %s must be an array of strings (received %s)"
         label (Json_util.kind_name other))
;;

let string_list_field_opt_result ?label ~field_name (json : Yojson.Safe.t) =
  match Json_util.assoc_member_opt field_name json with
  | Some `Null -> Ok []
  | _ -> string_list_field_result ?label ~field_name json
;;

let default_tool_access_of_meta_json () =
  (* Empty tools list means "all" — no restriction.  This replaces the
     previous default that enumerated Keeper_internal surface explicitly.
     See fleet deadlock Layer 2 analysis (2026-05-30). *)
  All
;;

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Json_util.assoc_member_opt "tool_access" json with
  | Some `Null -> Ok All
  | Some (`Assoc _ as access_json) ->
    let kind = Json_util.get_string access_json "kind" in
    (match kind with
     | Some "preset" ->
       (* Legacy preset entries: fall back to all-access. *)
       Log.Keeper.warn
         "keeper meta has deprecated tool_access.kind='preset'; \
          defaulting to all-access until next bootstrap";
       Ok All
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools ->
            let normalized = normalize_tool_names tools in
            if normalized = [] then Ok All else Ok (Custom normalized)
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None -> Ok All)
  | _ -> Ok All
;;
