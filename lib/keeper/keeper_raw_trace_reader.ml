(** See [keeper_raw_trace_reader.mli]. *)

type turn_summary =
  { file : string
  ; trace_id : string option
  ; bytes : int
  ; modified_at : float
  ; records : int
  }

type turn_record =
  { raw : string
  ; parsed : (Yojson.Safe.t, string) result
  }

type turn_records =
  { file : string
  ; total_records : int
  ; offset : int
  ; records : turn_record list
  }

type read_error =
  | Unknown_keeper of string
  | Invalid_file_name of string
  | No_such_turn of string
  | Read_failed of
      { file : string
      ; detail : string
      }

let read_error_to_string = function
  | Unknown_keeper keeper -> Printf.sprintf "invalid keeper name: %s" keeper
  | Invalid_file_name file ->
    Printf.sprintf
      "invalid raw-trace file name: %s; expected a bare file name ending in %s"
      file
      Keeper_types_support.raw_trace_file_extension
  | No_such_turn file -> Printf.sprintf "no raw trace named %s for this keeper" file
  | Read_failed { file; detail } ->
    Printf.sprintf "raw trace %s could not be read: %s" file detail
;;

(* A file name is a handle, not a path. Rejecting a separator outright — rather
   than taking the basename of whatever arrives — keeps the request that tried
   to leave the directory distinguishable from one that never did. *)
let validate_file_name file =
  let has_separator =
    String.exists (fun c -> Char.equal c '/' || Char.equal c '\\') file
  in
  let is_relative_step = String.equal file "." || String.equal file ".." in
  let has_extension =
    Filename.check_suffix file Keeper_types_support.raw_trace_file_extension
  in
  if String.equal (String.trim file) ""
     || has_separator
     || is_relative_step
     || not has_extension
  then Error (Invalid_file_name file)
  else Ok file
;;

let validate_keeper keeper =
  if Keeper_config.validate_name keeper then Ok keeper else Error (Unknown_keeper keeper)
;;

let nonblank_lines contents =
  String.split_on_char '\n' contents
  |> List.filter (fun line -> not (String.equal (String.trim line) ""))
;;

let trace_id_of_line line =
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
    (match List.assoc_opt "session_id" fields with
     | Some (`String value) when not (String.equal value "") -> Some value
     | Some _ | None -> None)
  | _ -> None
  | exception Yojson.Json_error _ -> None
;;

let summarize_records path =
  match Fs_compat.load_file_opt path with
  | None -> 0, None
  | Some contents ->
    let lines = nonblank_lines contents in
    let trace_ids = lines |> List.filter_map trace_id_of_line |> List.sort_uniq String.compare in
    let trace_id = match trace_ids with [ value ] -> Some value | [] | _ :: _ :: _ -> None in
    List.length lines, trace_id
;;

let list_turns ~config ~keeper ~limit =
  match validate_keeper keeper with
  | Error error -> Error error
  | Ok keeper ->
    if limit <= 0
    then Ok []
    else (
      let dir = Keeper_types_support.keeper_raw_trace_dir config keeper in
      if not (Sys.file_exists dir && Sys.is_directory dir)
      then Ok []
      else (
        let entries =
          Sys.readdir dir
          |> Array.to_list
          |> List.filter (fun entry ->
            Filename.check_suffix entry Keeper_types_support.raw_trace_file_extension)
        in
        let summaries =
          List.filter_map
            (fun file ->
               let path = Filename.concat dir file in
               match Unix.stat path with
               | { Unix.st_kind = Unix.S_REG; st_size; st_mtime; _ } ->
                 let records, trace_id = summarize_records path in
                 Some
                   { file
                   ; trace_id
                   ; bytes = st_size
                   ; modified_at = st_mtime
                   ; records
                   }
               | _ -> None
               | exception Unix.Unix_error _ -> None)
            entries
        in
        (* Newest first: an operator opening this list is looking for the turn
           that just happened, not the oldest one retained. *)
        let ordered =
          List.sort
            (fun a b ->
               match Float.compare b.modified_at a.modified_at with
               | 0 -> String.compare b.file a.file
               | order -> order)
            summaries
        in
        Ok (List.filteri (fun index _ -> index < limit) ordered)))
;;

let read_turn ~config ~keeper ~file ~offset ~limit =
  match validate_keeper keeper with
  | Error error -> Error error
  | Ok keeper ->
    (match validate_file_name file with
     | Error error -> Error error
     | Ok file ->
       let dir = Keeper_types_support.keeper_raw_trace_dir config keeper in
       let path = Filename.concat dir file in
       (match Fs_compat.load_file_opt path with
        | None -> Error (No_such_turn file)
        | Some contents ->
          let lines = nonblank_lines contents in
          let total_records = List.length lines in
          let offset = max 0 offset in
          let limit = max 0 limit in
          let records =
            lines
            |> List.filteri (fun index _ -> index >= offset && index < offset + limit)
            |> List.map (fun line ->
              let parsed =
                match Yojson.Safe.from_string line with
                | json -> Ok json
                | exception Yojson.Json_error message -> Error message
              in
              { raw = line; parsed })
          in
          Ok { file; total_records; offset; records })
       | exception Sys_error detail -> Error (Read_failed { file; detail }))
;;

let turn_summary_to_json (summary : turn_summary) =
  `Assoc
    [ "file", `String summary.file
    ; "trace_id", Json_util.string_opt_to_json summary.trace_id
    ; "bytes", `Int summary.bytes
    ; "modified_at", `Float summary.modified_at
    ; "records", `Int summary.records
    ]
;;

(* An unparseable line keeps its position and says so. Collapsing it to an
   omission would make a torn trace read as a shorter one. *)
let record_to_json record =
  match record.parsed with
  | Ok json -> `Assoc [ "ok", `Bool true; "raw", `String record.raw; "record", json ]
  | Error message ->
    `Assoc [ "ok", `Bool false; "raw", `String record.raw; "error", `String message ]
;;

let turn_records_to_json records =
  `Assoc
    [ "file", `String records.file
    ; "total_records", `Int records.total_records
    ; "offset", `Int records.offset
    ; "returned", `Int (List.length records.records)
    ; "records", `List (List.map record_to_json records.records)
    ]
;;
