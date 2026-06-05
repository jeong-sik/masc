(** Keeper meta tool-access helpers.

    A keeper's [tool_access] is the persisted candidate profile list —
    [keeper_meta.tool_access : string list]. Descriptor/registry availability,
    denylist filtering, per-turn OAS allowlists, and eval gates still constrain
    execution. There is no wrapper type. *)

open Keeper_types_profile

let normalize_tool_names names =
  names
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> dedupe_keep_order
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
     | Ok tools -> Ok (normalize_tool_names tools)
     | Error msg -> Error msg)
  | Some other ->
    Error
      (Printf.sprintf "keeper tool_access must be an array of strings (received %s)"
         (Json_util.kind_name other))
;;
