(** Keeper meta tool-access helpers.

    Included by [Keeper_meta_contract] so [Keeper_types.*] keeps the same
    public API.  A keeper's tool access is simply the list of tool names it
    may call — [keeper_meta.tool_access : string list].  There is no wrapper
    type: the allowlist IS the policy. *)

open Keeper_types_profile

let tool_names_include_board name_list =
  List.exists Keeper_tool_name.is_board_surface_name name_list
;;

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
;;

let write_tools = [ "tool_edit_file"; "tool_write_file"; "tool_execute" ]
;;

let normalize_tool_access names = normalize_tool_names names

(** Encode a tool allowlist as a JSON array of tool names. *)
let tool_access_to_json names = `List (List.map (fun s -> `String s) names)

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
  (* The Agent_internal surface was empty (agent_internal_surface_tools = []),
     so the default tool_access for keepers without an explicit list has always
     been the empty list; runtime filtering supplies the actual tool set.
     Surface deleted in the surface-cut refactor.
     See fleet deadlock Layer 2 analysis (2026-05-30) + runtime provider
     gap analysis (2026-05-30). *)
  normalize_tool_names []
;;

(** Parse [tool_access] from persisted meta JSON.
    Canonical form is a JSON array of tool names. *)
let tool_access_of_meta_json (json : Yojson.Safe.t) =
  match Json_util.assoc_member_opt "tool_access" json with
  | Some `Null | None -> Error "keeper tool_access must be an array of strings"
  | Some (`List _ as list_json) ->
    (match
       string_list_field_result ~field_name:"tool_access"
         (`Assoc [ "tool_access", list_json ])
     with
     | Ok tools -> Ok (normalize_tool_access tools)
     | Error msg -> Error msg)
  | Some other ->
    Error
      (Printf.sprintf "keeper tool_access must be an array of strings (received %s)"
         (Json_util.kind_name other))
;;
