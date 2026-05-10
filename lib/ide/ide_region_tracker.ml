(** IDE region tracker — extract code regions from Keeper tool_calls. *)

open Ide_annotation_types

let parse_hunk_header line =
  if not (String.starts_with ~prefix:"@@" line) then None
  else
    let parts = String.split_on_char ' ' line in
    let old_part =
      try List.nth parts 1 with
      | _ -> ""
    in
    let _new_part =
      try List.nth parts 2 with
      | _ -> ""
    in
    let parse_start s =
      let s =
        if String.length s > 0 && (s.[0] = '-' || s.[0] = '+') then
          String.sub s 1 (max 0 (String.length s - 1))
        else s
      in
      let comma = String.index_opt s ',' in
      match comma with
      | Some idx -> (
          match int_of_string_opt (String.sub s 0 idx) with
          | Some n -> Some n
          | None -> None)
      | None -> (
          match int_of_string_opt s with
          | Some n -> Some n
          | None -> None)
    in
    match parse_start old_part with
    | Some start -> Some (max 1 start)
    | None -> None

let count_lines s =
  if s = "" then 0
  else
    let n = ref 1 in
    for i = 0 to String.length s - 1 do
      if s.[i] = '\n' then incr n
    done;
    if s.[String.length s - 1] = '\n' then !n - 1 else !n

let line_range_of_hunk ~start ~lines =
  let count =
    List.fold_left
      (fun acc line ->
        if String.starts_with ~prefix:"+" line then acc + 1
        else if String.starts_with ~prefix:" " line then acc + 1
        else acc)
      0 lines
  in
  (start, start + count - 1)

let extract_regions_from_diff ~keeper_id ~file_path ~turn ~diff_text =
  let lines = String.split_on_char '\n' diff_text in
  let rec collect start_line acc remaining =
    match remaining with
    | [] -> List.rev acc
    | hd :: tl ->
        match parse_hunk_header hd with
        | Some start ->
            let hunk_lines, rest =
              let rec take_hunk acc' = function
                | [] -> (List.rev acc', [])
                | x :: xs when String.starts_with ~prefix:"@@" x ->
                    (List.rev acc', x :: xs)
                | x :: xs -> take_hunk (x :: acc') xs
              in
              take_hunk [] tl
            in
            let s, e = line_range_of_hunk ~start ~lines:hunk_lines in
            let region =
              {
                file_path;
                line_start = s;
                line_end = e;
                keeper_id;
                source = Tool_call { tool_name = "edit_file"; turn };
                timestamp_ms = Int64.of_float (Unix.gettimeofday () *. 1000.0);
              }
            in
            collect start_line (region :: acc) rest
        | None -> collect start_line acc tl
  in
  collect 1 [] lines

let extract_region_from_full_file ~keeper_id ~file_path ~turn ~content =
  let n = count_lines content in
  {
    file_path;
    line_start = 1;
    line_end = max 1 n;
    keeper_id;
    source = Tool_call { tool_name = "write_file"; turn };
    timestamp_ms = Int64.of_float (Unix.gettimeofday () *. 1000.0);
  }

let is_file_write_tool name =
  name = "write_file" || name = "edit_file" || name = "apply_patch"

let json_string_field key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`String s) when s <> "" -> Some s
      | _ -> None)
  | _ -> None

let ingest_tool_call ~base_dir ~keeper_id ~turn json =
  let tool_name =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt "name" fields with
        | Some (`String n) -> n
        | _ -> "")
    | _ -> ""
  in
  if not (is_file_write_tool tool_name) then ()
  else
    let arguments =
      match json with
      | `Assoc fields -> (
          match List.assoc_opt "arguments" fields with
          | Some (`Assoc args) -> args
          | _ -> [])
      | _ -> []
    in
    let file_path =
      match List.assoc_opt "path" arguments with
      | Some (`String s) when s <> "" -> Some s
      | _ -> (
          match List.assoc_opt "file_path" arguments with
          | Some (`String s) when s <> "" -> Some s
          | _ -> None)
    in
    match file_path with
    | None -> ()
    | Some fp ->
        let regions =
          if tool_name = "write_file" then
            match List.assoc_opt "content" arguments with
            | Some (`String content) -> [extract_region_from_full_file ~keeper_id ~file_path:fp ~turn ~content]
            | _ -> []
          else
            match List.assoc_opt "diff" arguments with
            | Some (`String diff_text) -> extract_regions_from_diff ~keeper_id ~file_path:fp ~turn ~diff_text
            | _ -> (
                match List.assoc_opt "patch" arguments with
                | Some (`String patch_text) -> extract_regions_from_diff ~keeper_id ~file_path:fp ~turn ~diff_text:patch_text
                | _ -> [])
        in
        let store_dir = Filename.concat base_dir ".masc-ide" in
        if not (Sys.file_exists store_dir && Sys.is_directory store_dir) then
          Unix.mkdir store_dir 0o755;
        let store = Dated_jsonl.create ~base_dir:store_dir () in
        List.iter (fun r -> Dated_jsonl.append store (region_to_json r)) regions
