(** Receipt helpers used by task scheduling. *)

open Masc_domain
open Workspace_utils

let ( let* ) = Result.bind

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

type receipt_read_error =
  | Agent_record_read_failed of { path : string; message : string }
  | Directory_stat_failed of { path : string; message : string }
  | Directory_list_failed of { path : string; message : string }
  | Receipt_line_read_failed of { path : string; message : string }
  | Receipt_json_parse_failed of { path : string; message : string }

let receipt_read_error_to_string = function
  | Agent_record_read_failed { path; message } ->
    Printf.sprintf "agent record read failed for %s: %s" path message
  | Directory_stat_failed { path; message } ->
    Printf.sprintf "directory stat failed for %s: %s" path message
  | Directory_list_failed { path; message } ->
    Printf.sprintf "directory list failed for %s: %s" path message
  | Receipt_line_read_failed { path; message } ->
    Printf.sprintf "receipt line read failed for %s: %s" path message
  | Receipt_json_parse_failed { path; message } ->
    Printf.sprintf "receipt JSON parse failed for %s: %s" path message
;;

let read_agent_error_message = function
  | Agent_fd_pressure exn -> "fd_pressure_io: " ^ Printexc.to_string exn
  | Agent_read_error msg -> msg
;;

let warn_receipt_read_error site error =
  Log.Workspace.warn
    "%s: %s"
    site
    (receipt_read_error_to_string error)
;;

let agent_record_keeper_name_result config ~agent_name =
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if path_exists config agent_file
  then
    match read_agent_with_repair_result config agent_file with
    | Ok { meta = Some { keeper_name = Some name; _ }; _ } ->
      let name = String.trim name in
      Ok (if name = "" then None else Some name)
    | Ok _ -> Ok None
    | Error error ->
      Error
        (Agent_record_read_failed
           { path = agent_file; message = read_agent_error_message error })
  else Ok None
;;

let agent_record_keeper_name config ~agent_name =
  match agent_record_keeper_name_result config ~agent_name with
  | Ok keeper_name -> keeper_name
  | Error error ->
    warn_receipt_read_error "agent_record_keeper_name" error;
    None
;;

let receipt_candidate_names ~agent_name record_keeper_name =
  let base =
    [ record_keeper_name; keeper_name_from_agent_name agent_name; Some agent_name ]
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

let keeper_receipt_candidate_names_result config ~agent_name =
  let* record_keeper_name = agent_record_keeper_name_result config ~agent_name in
  Ok (receipt_candidate_names ~agent_name record_keeper_name)
;;

let keeper_receipt_candidate_names config ~agent_name =
  match keeper_receipt_candidate_names_result config ~agent_name with
  | Ok names -> names
  | Error error ->
    warn_receipt_read_error "keeper_receipt_candidate_names" error;
    receipt_candidate_names ~agent_name None
;;

let directory_exists_result path =
  match Sys.file_exists path && Sys.is_directory path with
  | exists -> Ok exists
  | exception Sys_error message -> Error (Directory_stat_failed { path; message })
;;

let directory_exists path =
  match directory_exists_result path with
  | Ok exists -> exists
  | Error error ->
    warn_receipt_read_error "directory_exists" error;
    false
;;

let directory_entries_result path =
  match Sys.readdir path |> Array.to_list with
  | entries -> Ok entries
  | exception Sys_error message -> Error (Directory_list_failed { path; message })
;;

let directory_entries path =
  match directory_entries_result path with
  | Ok entries -> entries
  | Error error ->
    warn_receipt_read_error "directory_entries" error;
    []
;;

let jsonl_files_under_result base_dir =
  let* base_exists = directory_exists_result base_dir in
  if not base_exists
  then Ok []
  else
    let* month_entries = directory_entries_result base_dir in
    let rec month_dirs acc = function
      | [] -> Ok (List.rev acc)
      | month :: rest ->
        let month_dir = Filename.concat base_dir month in
        let* is_dir = directory_exists_result month_dir in
        month_dirs (if is_dir then month_dir :: acc else acc) rest
    in
    let* month_dirs = month_dirs [] month_entries in
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | month_dir :: rest ->
        let* entries = directory_entries_result month_dir in
        let files =
          entries
          |> List.filter (String.ends_with ~suffix:".jsonl")
          |> List.map (Filename.concat month_dir)
        in
        collect (List.rev_append files acc) rest
    in
    collect [] month_dirs
;;

let jsonl_files_under base_dir =
  match jsonl_files_under_result base_dir with
  | Ok files -> files
  | Error error ->
    warn_receipt_read_error "jsonl_files_under" error;
    []
;;

let last_nonempty_line_result path =
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
    |> fun line -> Ok line
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error message -> Error (Receipt_line_read_failed { path; message })
;;

let last_nonempty_line path =
  match last_nonempty_line_result path with
  | Ok line -> line
  | Error error ->
    warn_receipt_read_error "last_nonempty_line" error;
    None
;;

let latest_json_in_receipt_dir_result base_dir =
  let* files = jsonl_files_under_result base_dir in
  let rec latest_json = function
    | [] -> Ok None
    | path :: rest ->
      let* line = last_nonempty_line_result path in
      (match line with
       | None -> latest_json rest
       | Some line ->
         (match Yojson.Safe.from_string line with
          | json -> Ok (Some json)
          | exception Yojson.Json_error message ->
            Error (Receipt_json_parse_failed { path; message })))
  in
  files |> List.sort (fun a b -> compare b a) |> latest_json
;;

let latest_json_in_receipt_dir base_dir =
  match latest_json_in_receipt_dir_result base_dir with
  | Ok json -> json
  | Error error ->
    warn_receipt_read_error "latest_json_in_receipt_dir" error;
    None
;;

let json_member_path path json =
  List.fold_left
    (fun current key ->
       match Json_util.assoc_member_opt key current with
       | Some v -> v
       | None -> `Null)
    json path
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

let latest_execution_receipt_json_result config ~agent_name =
  let keeper_root = keepers_runtime_dir config in
  let* candidate_names = keeper_receipt_candidate_names_result config ~agent_name in
  let rec collect receipts = function
    | [] -> Ok receipts
    | keeper_name :: rest ->
      let base_dir =
        Filename.concat (Filename.concat keeper_root keeper_name) "execution-receipts"
      in
      let* receipt = latest_json_in_receipt_dir_result base_dir in
      collect (match receipt with None -> receipts | Some json -> json :: receipts) rest
  in
  let* receipts = collect [] candidate_names in
  receipts
  |> List.sort (fun a b -> compare (receipt_sort_key b) (receipt_sort_key a))
  |> List.find_opt (fun _ -> true)
  |> fun receipt -> Ok receipt
;;

let latest_execution_receipt_json config ~agent_name =
  match latest_execution_receipt_json_result config ~agent_name with
  | Ok receipt -> receipt
  | Error error ->
    warn_receipt_read_error "latest_execution_receipt_json" error;
    None
;;
