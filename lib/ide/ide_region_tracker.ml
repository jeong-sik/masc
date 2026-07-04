(** IDE region tracker — extract code regions from Keeper tool_calls. *)

open Ide_annotation_types

let parse_hunk_header line =
  if not (String.starts_with ~prefix:"@@" line) then None
  else
    let parts = String.split_on_char ' ' line in
    (* RFC-0145 — [List.nth] raises [Failure "nth"] on out-of-bounds;
       narrow the wildcard catch-all to that one exception so unrelated
       runtime failures propagate to the caller. *)
    let old_part =
      try List.nth parts 1 with
      | Failure _ -> ""
    in
    let _new_part =
      try List.nth parts 2 with
      | Failure _ -> ""
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

let extract_regions_from_diff ~keeper_id ~file_path ~turn ~tool_name ~diff_text =
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
                source = Tool_call { tool_name; turn };
                timestamp_ms = Int64.of_float (Unix.gettimeofday () *. 1000.0);
              }
            in
            collect start_line (region :: acc) rest
        | None -> collect start_line acc tl
  in
  collect 1 [] lines

let extract_region_from_full_file ~keeper_id ~file_path ~turn ~tool_name ~content =
  let n = count_lines content in
  {
    file_path;
    line_start = 1;
    line_end = max 1 n;
    keeper_id;
    source = Tool_call { tool_name; turn };
    timestamp_ms = Int64.of_float (Unix.gettimeofday () *. 1000.0);
  }

let is_file_write_tool name =
  name = "write_file" || name = "edit_file" || name = "apply_patch"

let regions_file ~base_dir ?(partition = Ide_paths.Legacy_default) () =
  Filename.concat (Ide_paths.partition_store_dir ~base_dir partition) "regions.jsonl"

let rec ensure_dir path =
  if path = "" || path = "/" || (Sys.file_exists path && Sys.is_directory path)
  then ()
  else (
    ensure_dir (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let append_region ~base_dir ?(partition = Ide_paths.Legacy_default) region =
  let path = regions_file ~base_dir ~partition () in
  ensure_dir (Filename.dirname path);
  Fs_compat.append_jsonl path (region_to_json region)

(* RFC-0128 §5 — read-side helpers. Regions are append-only; reads do
   not mutate. *)

let load_regions_from_path ?file_path path =
  if not (Sys.file_exists path) then []
  else
    Fs_compat.fold_jsonl_lines
      ~init:[]
      ~f:(fun acc ~line_no:_ json ->
        match region_of_json json with
        | Ok (r : code_region) ->
          (match file_path with
           | None -> r :: acc
           | Some fp -> if r.file_path = fp then r :: acc else acc)
        | Error _ -> acc)
      path
    |> List.rev

let region_key (r : code_region) =
  let src_tag =
    match r.source with
    | Tool_call { tool_name; turn } ->
      Printf.sprintf "tc:%s:%d" tool_name turn
    | Manual { note } ->
      Printf.sprintf "manual:%s" note
  in
  Printf.sprintf
    "%s|%s|%d|%d|%Ld|%s"
    r.keeper_id
    r.file_path
    r.line_start
    r.line_end
    r.timestamp_ms
    src_tag

let read_regions ~base_dir ?(partition = Ide_paths.Legacy_default) ?file_path () =
  load_regions_from_path ?file_path (regions_file ~base_dir ~partition ())

let ingest_tool_call ~base_dir ?(partition = Ide_paths.Legacy_default) ~keeper_id ~turn json =
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
        (* Region-extraction priority per tool_name:
             write_file → "content" → full-file region.
             edit_file / apply_patch → "diff" or "patch" hunks (preferred,
               preserves the changed line ranges only) → fall back to
               "content" full-file region when only the post-edit
               content is available.
           RFC-0128 PR-1e: the content fallback for edit_file/apply_patch
           used to be served by Ide_meta_sync.flush_regions, which wrote
           to the flat store and produced a double-write against the
           by-url partition once PR-1c routed ingest_tool_call. Moving the
           fallback into ingest_tool_call lets us drop the meta_sync call
           site so all keeper write records land in a single, consistent
           partition bucket. *)
        let extract_full_file () =
          match List.assoc_opt "content" arguments with
          | Some (`String content) ->
            [ extract_region_from_full_file ~keeper_id ~file_path:fp ~turn ~tool_name ~content ]
          | _ -> []
        in
        let regions =
          if tool_name = "write_file" then extract_full_file ()
          else
            match List.assoc_opt "diff" arguments with
            | Some (`String diff_text) ->
              extract_regions_from_diff ~keeper_id ~file_path:fp ~turn ~tool_name ~diff_text
            | _ ->
              (match List.assoc_opt "patch" arguments with
               | Some (`String patch_text) ->
                 extract_regions_from_diff
                   ~keeper_id
                   ~file_path:fp
                   ~turn
                   ~tool_name
                   ~diff_text:patch_text
               | _ -> extract_full_file ())
        in
        List.iter (append_region ~base_dir ~partition) regions
