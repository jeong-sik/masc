(** Keeper meta tool-access contract and JSON helpers.

    Included by [Keeper_meta_contract] so [Keeper_types.*] keeps the same
    public API while tool preset/access policy is isolated from the broader
    keeper meta runtime contract. *)

open Keeper_types_profile

type tool_access = Custom of Tool_name.Keeper.t list

let tool_names_include_board name_list =
  List.exists Tool_name.Keeper.is_board name_list
;;

let tool_access_default_room_signal_prompt_enabled ~default = function
  | Custom tool_names -> default || tool_names_include_board tool_names
;;

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

(** Convert a raw string list (from TOML/JSON) into a typed [tool_access].
    Unknown names are silently dropped. *)
let tool_access_of_string_list names =
  Custom (names |> normalize_tool_names |> List.filter_map Tool_name.Keeper.of_string)
;;

let normalize_tool_names_variant names =
  names |> dedupe_keep_order
;;


let normalize_tool_access (Custom names) = Custom (normalize_tool_names_variant names)

let tool_access_custom_allowlist (Custom names) =
  List.map Tool_name.Keeper.to_string names

let tool_access_to_json (Custom names) =
  `Assoc
    [ "kind", `String "custom"; "tools", `List (List.map (fun s -> `String (Tool_name.Keeper.to_string s)) names) ]
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
  (* tool_execute excluded from the default blocklist: keepers need it for
     shell commands, file reads, git ops, and cascade tool filtering requires
     it. Only file-mutation writes (edit/write_file) are blocked by default.
     See fleet deadlock Layer 2 analysis (2026-05-30). *)
  let tools =
    Tool_catalog.tools_for_surface Tool_catalog.Keeper_internal
    |> List.filter_map Tool_name.Keeper.of_string
    |> List.filter (fun k ->
           match k with
           | Tool_name.Keeper.Fs_edit -> false
           | _ -> true)
  in
  Custom (normalize_tool_names_variant tools)
;;

let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Json_util.assoc_member_opt "tool_access" json with
  | Some `Null -> Ok (default_tool_access_of_meta_json ())
  | Some (`Assoc _ as access_json) ->
    let kind = Json_util.get_string access_json "kind" in
    (match kind with
     | Some "preset" ->
       (* Legacy preset entries: fall back to default access.
          Keeper bootstrap resyncs from TOML which now requires explicit custom lists. *)
       Log.Keeper.warn
         "keeper meta has deprecated tool_access.kind='preset'; \
          defaulting to keeper_internal surface until next bootstrap";
       Ok (default_tool_access_of_meta_json ())
     | Some "custom" ->
       (match
          string_list_field_result
            ~field_name:"tools"
            ~label:"tool_access.tools"
            access_json
        with
        | Ok tools ->
          Ok (normalize_tool_access (Custom (List.filter_map Tool_name.Keeper.of_string tools)))
        | Error msg -> Error msg)
     | Some other -> Error (Printf.sprintf "invalid keeper tool_access.kind: %s" other)
     | None ->
       (* Empty tool_access: {} — missing kind field.
          Safe to default: ensure_keeper_meta resyncs from TOML on bootstrap.
          Without this, meta_of_json fails and recovery via
          load_or_materialize_boot_meta also fails (handle_keeper_up calls
          read_meta which hits the same parse error). *)
       Ok (default_tool_access_of_meta_json ()))
  | _ ->
    (* tool_access missing or not an object — same recovery rationale. *)
    Ok (default_tool_access_of_meta_json ())
;;
