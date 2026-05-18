(** Receipt helpers used by coord task scheduling claim gates. *)

open Masc_domain
open Coord_utils

(* Build [allowed] as a [(name, unit) Hashtbl.t] once. Constant
   initial bucket size avoids the [List.length allowed] pre-traversal
   (Hashtbl grows automatically); [allowed] is typically the agent's
   tool surface, ~30-50 names. *)
let build_allowed_set allowed =
  let set = Hashtbl.create 32 in
  List.iter
    (fun name ->
       Hashtbl.replace set (Coord_task_classify.canonical_required_tool_name name) ())
    allowed;
  set
;;

let underscore_name name =
  String.map
    (function
      | '-' -> '_'
      | c -> c)
    name
;;

let hyphen_name name =
  String.map
    (function
      | '_' -> '-'
      | c -> c)
    name
;;

let keeper_name_from_agent_name agent_name =
  let trimmed = String.trim agent_name in
  if
    String.starts_with ~prefix:"keeper-" trimmed
    && String.ends_with ~suffix:"-agent" trimmed
    && String.length trimmed > 13
  then Some (String.sub trimmed 7 (String.length trimmed - 13))
  else if String.ends_with ~suffix:"-agent" trimmed && String.length trimmed > 6
  then Some (String.sub trimmed 0 (String.length trimmed - 6))
  else None
;;

let agent_record_keeper_name config ~agent_name =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file
  then (
    match read_agent_with_repair config agent_file with
    | Ok { meta = Some { keeper_name = Some name; _ }; _ } ->
      let name = String.trim name in
      if name = "" then None else Some name
    | Ok _ | Error _ -> None)
  else None
;;

let keeper_receipt_candidate_names config ~agent_name =
  let base =
    [ agent_record_keeper_name config ~agent_name
    ; keeper_name_from_agent_name agent_name
    ; Some agent_name
    ]
    |> List.filter_map Fun.id
  in
  base
  |> List.concat_map (fun name ->
    let trimmed = String.trim name in
    if trimmed = ""
    then []
    else [ trimmed; safe_filename trimmed; underscore_name trimmed; hyphen_name trimmed ])
  |> List.sort_uniq String.compare
;;

let directory_exists path =
  try Sys.file_exists path && Sys.is_directory path with
  | Sys_error _ -> false
;;

let directory_entries path =
  try Sys.readdir path |> Array.to_list with
  | Sys_error _ -> []
;;

let jsonl_files_under base_dir =
  if not (directory_exists base_dir)
  then []
  else
    directory_entries base_dir
    |> List.filter_map (fun month ->
      let month_dir = Filename.concat base_dir month in
      if directory_exists month_dir then Some month_dir else None)
    |> List.concat_map (fun month_dir ->
      directory_entries month_dir
      |> List.filter (String.ends_with ~suffix:".jsonl")
      |> List.map (Filename.concat month_dir))
;;

let last_nonempty_line path =
  try
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input)
      (fun () ->
         let rec loop last =
           match input_line input with
           | line ->
             let trimmed = String.trim line in
             loop (if trimmed = "" then last else Some trimmed)
           | exception End_of_file -> last
         in
         loop None)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error _ -> None
;;

let latest_json_in_receipt_dir base_dir =
  jsonl_files_under base_dir
  |> List.sort (fun a b -> compare b a)
  |> List.find_map (fun path ->
    match last_nonempty_line path with
    | None -> None
    | Some line ->
      (try Some (Yojson.Safe.from_string line) with
       | Yojson.Json_error _ -> None))
;;

let json_member_path path json =
  List.fold_left (fun current key -> Yojson.Safe.Util.member key current) json path
;;

let json_raw_string_path path json =
  match json_member_path path json with
  | `String value -> Some (String.trim value)
  | _ -> None
;;

let json_string_path path json =
  json_raw_string_path path json |> Option.map String.lowercase_ascii
;;

let receipt_sort_key json =
  match json_raw_string_path [ "recorded_at" ] json with
  | Some value -> value
  | None -> Option.value ~default:"" (json_raw_string_path [ "ended_at" ] json)
;;

let latest_execution_receipt_json config ~agent_name =
  let keeper_root = Filename.concat (masc_root_dir config) "keepers" in
  keeper_receipt_candidate_names config ~agent_name
  |> List.filter_map (fun keeper_name ->
    let base_dir =
      Filename.concat (Filename.concat keeper_root keeper_name) "execution-receipts"
    in
    latest_json_in_receipt_dir base_dir)
  |> List.sort (fun a b -> compare (receipt_sort_key b) (receipt_sort_key a))
  |> List.find_opt (fun _ -> true)
;;

let json_string_list key json =
  match Yojson.Safe.Util.member key json with
  | `List items ->
    List.filter_map
      (function
        | `String value ->
          let trimmed = String.trim value in
          if trimmed = "" then None else Some trimmed
        | _ -> None)
      items
  | _ -> []
;;

let latest_receipt_blocks_required_tool_claim config ~agent_name ~required_tools =
  match latest_execution_receipt_json config ~agent_name with
  | None -> false
  | Some receipt ->
    let operator_reason = json_string_path [ "operator_disposition_reason" ] receipt in
    let tool_contract_result = json_string_path [ "tool_contract_result" ] receipt in
    let tool_requirement =
      json_string_path [ "tool_surface"; "tool_requirement" ] receipt
    in
    let tools_used = json_string_list "tools_used" receipt in
    let degraded_contract =
      match tool_contract_result with
      | Some
          ( "violated"
          | "unknown"
          | "satisfied_by_deterministic_fallback"
          | "needs_execution_progress"
          | "missing_required_tool_use"
          | "passive_only"
          | "claim_only_after_owned_task"
          | "tool_surface_mismatch"
          | "no_tool_capable_provider" ) -> true
      | Some _ | None -> false
    in
    let visible_tools =
      json_string_list "requested_tools" receipt
      @ json_string_list "canonical_tools" receipt
      @ tools_used
    in
    let visible_set = build_allowed_set visible_tools in
    let required_tool_visible =
      List.exists
        (fun required_tool ->
           Hashtbl.mem
             visible_set
             (Coord_task_classify.canonical_required_tool_name required_tool))
        required_tools
    in
    (operator_reason = Some "tool_required_no_tools"
     || degraded_contract
     || (tool_requirement = Some "required" && tools_used = []))
    && not required_tool_visible
;;
