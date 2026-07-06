(** Offline mention backfill — see the interface for the contract. *)

type file_report = {
  path : string;
  total_lines : int;
  rewritten : int;
}

type line_result =
  | Line_unchanged
  | Line_rewritten of string
  | Line_error of string

type file_error = {
  path : string;
  line_no : int;
  message : string;
}

let validate_existing_mentions fields =
  match List.assoc_opt "mentions" fields with
  | None -> Ok false
  | Some (`List items) ->
    let rec loop = function
      | [] -> Ok true
      | `String value :: rest ->
        (match Keeper_identity.Keeper_id.of_string value with
         | Some _ -> loop rest
         | None -> Error "mentions contains a blank keeper id")
      | _ :: _ -> Error "mentions must contain only strings"
    in
    loop items
  | Some _ -> Error "mentions must be a list"
;;

let required_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s must be a string" key)
  | None -> Error (Printf.sprintf "%s string field is required" key)
;;

let backfill_object fields =
  match required_string_field fields "role" with
  | Error message -> Error message
  | Ok role when not (String.equal role "user") -> Ok Line_unchanged
  | Ok _ ->
    match validate_existing_mentions fields with
    | Error message -> Error message
    | Ok true -> Ok Line_unchanged
    | Ok false ->
      match required_string_field fields "content" with
      | Error message -> Error message
      | Ok content ->
        match Keeper_lane_mentions.mention_ids_of_content content with
        | [] -> Ok Line_unchanged
        | ids ->
          let mentions_field =
            ( "mentions"
            , `List
                (List.map
                   (fun id -> `String (Keeper_identity.Keeper_id.to_string id))
                   ids) )
          in
          Ok
            (Line_rewritten
               (Yojson.Safe.to_string (`Assoc (fields @ [ mentions_field ]))))
;;

let backfill_line (line : string) : line_result =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error message -> Line_error ("invalid JSON: " ^ message)
  | `Assoc fields ->
    (match backfill_object fields with
     | Ok result -> result
     | Error message -> Line_error message)
  | _ -> Line_error "row must be a JSON object"

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

let write_lines_atomically path lines =
  let tmp = path ^ ".backfill-tmp" in
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

let collect_line_results path lines =
  let rewritten = ref 0 in
  let errors = ref [] in
  let out_lines =
    lines
    |> List.mapi (fun idx line ->
      match backfill_line line with
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

let backfill_file ~dry_run path =
  match read_lines path with
  | Error message -> Error [ { path; line_no = 0; message } ]
  | Ok lines ->
    let out_lines, rewritten, errors = collect_line_results path lines in
    if errors <> []
    then Error errors
    else if dry_run || rewritten = 0
    then Ok { path; total_lines = List.length lines; rewritten }
    else (
      match write_lines_atomically path out_lines with
      | Ok () -> Ok { path; total_lines = List.length lines; rewritten }
      | Error message -> Error [ { path; line_no = 0; message } ])

let backfill_base_path ~dry_run base_path =
  let dir =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "keeper_chat"
  in
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then Ok []
  else
    let reports = ref [] in
    let errors = ref [] in
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
    |> List.sort String.compare
    |> List.iter (fun name ->
      let path = Filename.concat dir name in
      match backfill_file ~dry_run path with
      | Ok report -> reports := report :: !reports
      | Error file_errors -> errors := file_errors @ !errors);
    match List.rev !errors with
    | [] -> Ok (List.rev !reports)
    | file_errors -> Error file_errors
