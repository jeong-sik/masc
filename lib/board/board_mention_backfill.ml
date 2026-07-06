(** Offline board mention-id backfill. See the interface for the contract. *)

type target =
  | Posts
  | Comments

type line_result =
  | Line_unchanged
  | Line_rewritten of string
  | Line_error of string

type file_error = {
  path : string;
  line_no : int;
  message : string;
}

type file_report = {
  path : string;
  target : target;
  total_lines : int;
  rewritten : int;
}

let ( let* ) = Result.bind

let target_to_string = function
  | Posts -> "board_posts"
  | Comments -> "board_comments"
;;

let target_filename = function
  | Posts -> "board_posts.jsonl"
  | Comments -> "board_comments.jsonl"
;;

let board_root_for_base_path ~base_path =
  Workspace_utils.masc_root_dir_from
    ~base_path
    ~cluster_name:(Env_config_core.cluster_name ())
;;

let path_for_target ~base_path target =
  Filename.concat (board_root_for_base_path ~base_path) (target_filename target)
;;

let mention_ids_to_yojson ids =
  `List
    (List.map
       (fun id -> `String (Board_types.Mention_id.to_string id))
       ids)
;;

let add_mention_ids_field fields ids =
  `Assoc (fields @ [ "mention_ids", mention_ids_to_yojson ids ])
;;

let string_field fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "%s must be a string when present" key)
;;

let required_string_field fields key =
  match string_field fields key with
  | Ok (Some value) -> Ok value
  | Ok None -> Error (Printf.sprintf "%s string field is required" key)
  | Error _ as err -> err
;;

let validate_existing_mention_ids fields =
  match List.assoc_opt "mention_ids" fields with
  | None -> Ok false
  | Some (`List items) ->
    let rec loop = function
      | [] -> Ok true
      | `String value :: rest ->
        (match Board_types.Mention_id.of_string value with
         | Some _ -> loop rest
         | None -> Error "mention_ids contains a blank id")
      | _ :: _ -> Error "mention_ids must contain only strings"
    in
    loop items
  | Some _ -> Error "mention_ids must be a list"
;;

let post_mentions fields =
  let* content = required_string_field fields "content" in
  let* title = string_field fields "title" in
  let* body = string_field fields "body" in
  let raw_body = Option.value body ~default:content in
  let _state_block, stripped_body =
    Board_core_payload.extract_state_block raw_body
  in
  let normalized_body = String.trim stripped_body in
  let normalized_title =
    match title with
    | Some value ->
      let trimmed = String.trim value in
      if String.equal trimmed ""
      then Board_core_payload.derive_post_title normalized_body
      else trimmed
    | None -> Board_core_payload.derive_post_title normalized_body
  in
  Ok
    (Board_types.Mention_id.mention_ids_of_post_fields
       ~title:normalized_title
       ~body:normalized_body)
;;

let comment_mentions fields =
  let* content = required_string_field fields "content" in
  Ok (Board_types.Mention_id.mention_ids_of_content content)
;;

let mentions_for_target target fields =
  match target with
  | Posts -> post_mentions fields
  | Comments -> comment_mentions fields
;;

let backfill_object ~target fields =
  let* already_has_mention_ids = validate_existing_mention_ids fields in
  if already_has_mention_ids
  then Ok Line_unchanged
  else
    let* mention_ids = mentions_for_target target fields in
    match mention_ids with
    | [] -> Ok Line_unchanged
    | ids -> Ok (Line_rewritten (Yojson.Safe.to_string (add_mention_ids_field fields ids)))
;;

let backfill_line ~target line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error message -> Line_error ("invalid JSON: " ^ message)
  | `Assoc fields ->
    (match backfill_object ~target fields with
     | Ok result -> result
     | Error message -> Line_error message)
  | _ -> Line_error "row must be a JSON object"
;;

let read_lines path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | line -> loop (line :: acc)
          | exception End_of_file -> Ok (List.rev acc)
        in
        loop [])
  with
  | Sys_error message -> Error message
;;

let write_lines_atomically path lines =
  let tmp = path ^ ".board-mention-backfill-tmp" in
  try
    let oc = open_out_bin tmp in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () ->
        List.iter
          (fun line ->
            output_string oc line;
            output_char oc '\n')
          lines);
    Sys.rename tmp path;
    Ok ()
  with
  | Sys_error message -> Error message
;;

let collect_line_results ~target path lines =
  let rewritten = ref 0 in
  let errors = ref [] in
  let out_lines =
    lines
    |> List.mapi (fun idx line ->
      match backfill_line ~target line with
      | Line_unchanged -> line
      | Line_rewritten replacement ->
        incr rewritten;
        replacement
      | Line_error message ->
        errors := { path; line_no = idx + 1; message } :: !errors;
        line)
  in
  out_lines, !rewritten, List.rev !errors
;;

let backfill_file ~dry_run ~target path =
  match read_lines path with
  | Error message -> Error [ { path; line_no = 0; message } ]
  | Ok lines ->
    let out_lines, rewritten, errors = collect_line_results ~target path lines in
    if errors <> []
    then Error errors
    else if dry_run || rewritten = 0
    then Ok { path; target; total_lines = List.length lines; rewritten }
    else (
      match write_lines_atomically path out_lines with
      | Ok () -> Ok { path; target; total_lines = List.length lines; rewritten }
      | Error message -> Error [ { path; line_no = 0; message } ])
;;

let backfill_base_path ~dry_run base_path =
  let targets = [ Posts; Comments ] in
  let existing =
    targets
    |> List.filter_map (fun target ->
      let path = path_for_target ~base_path target in
      if Sys.file_exists path then Some (target, path) else None)
  in
  let reports = ref [] in
  let errors = ref [] in
  List.iter
    (fun (target, path) ->
      match backfill_file ~dry_run ~target path with
      | Ok report -> reports := report :: !reports
      | Error file_errors -> errors := file_errors @ !errors)
    existing;
  match List.rev !errors with
  | [] -> Ok (List.rev !reports)
  | file_errors -> Error file_errors
;;
