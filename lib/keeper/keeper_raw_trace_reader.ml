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
  | Invalid_trace_record of
      { file : string
      ; line : int
      ; detail : string
      }
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
  | Invalid_trace_record { file; line; detail } ->
    Printf.sprintf "raw trace %s has invalid identity at line %d: %s" file line detail
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

let trace_id_of_line ~file ~line_number line =
  let invalid detail = Error (Invalid_trace_record { file; line = line_number; detail }) in
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
    (match List.filter (fun (name, _) -> String.equal name "session_id") fields with
     | [ _, `String value ] ->
       (match Keeper_id.Trace_id.of_string value with
        | Ok trace_id -> Ok trace_id
        | Error detail -> invalid detail)
     | [] -> invalid "missing session_id"
     | [ _ ] -> invalid "session_id must be a string"
     | _ :: _ :: _ -> invalid "duplicate session_id fields")
  | _ -> invalid "record must be a JSON object"
  | exception Yojson.Json_error detail -> invalid detail
;;

let summarize_records ~file contents =
  let lines = nonblank_lines contents in
  let rec loop line_number expected = function
    | [] -> Ok (List.length lines, Option.map Keeper_id.Trace_id.to_string expected)
    | line :: rest ->
      (match trace_id_of_line ~file ~line_number line with
       | Error _ as error -> error
       | Ok trace_id ->
         (match expected with
          | None -> loop (line_number + 1) (Some trace_id) rest
          | Some expected when Keeper_id.Trace_id.equal expected trace_id ->
            loop (line_number + 1) (Some expected) rest
          | Some expected ->
            Error
              (Invalid_trace_record
                 { file
                 ; line = line_number
                 ; detail =
                     Printf.sprintf
                       "session_id %s does not match %s"
                       (Keeper_id.Trace_id.to_string trace_id)
                       (Keeper_id.Trace_id.to_string expected)
                 })))
  in
  loop 1 None lines
;;

let list_turns ~config ~keeper ~limit =
  match validate_keeper keeper with
  | Error error -> Error error
  | Ok keeper ->
    if limit <= 0
    then Ok []
    else (
      let dir = Keeper_types_support.keeper_raw_trace_dir config keeper in
      match Fs_compat.inspect_owned_directory_chain ~ownership_root:config.base_path dir with
      | Ok Fs_compat.Owned_directory_missing -> Ok []
      | Error rejection ->
        Error
          (Read_failed
             { file = dir
             ; detail = Fs_compat.owned_directory_chain_rejection_to_string rejection
             })
      | Ok (Fs_compat.Owned_directory _) ->
        let entries =
          try
            Ok
              (Sys.readdir dir
               |> Array.to_list
               |> List.filter (fun entry ->
                    Filename.check_suffix
                      entry
                      Keeper_types_support.raw_trace_file_extension))
          with
          | Sys_error detail -> Error (Read_failed { file = dir; detail })
        in
        let rec read_summaries acc = function
          | [] -> Ok (List.rev acc)
          | file :: rest ->
            let path = Filename.concat dir file in
            (match
               Fs_compat.load_owned_regular_file_with_snapshot
                 ~ownership_root:config.base_path
                 path
             with
             | Error error ->
               Error
                 (Read_failed
                    { file
                    ; detail = Fs_compat.owned_regular_file_read_error_to_string error
                    })
             | Ok None -> Error (Read_failed { file; detail = "file disappeared during listing" })
             | Ok (Some contents) ->
               (match summarize_records ~file contents.content with
                | Error _ as error -> error
                | Ok (records, trace_id) ->
                  read_summaries
                    ({ file
                     ; trace_id
                     ; bytes = contents.snapshot.file_size
                     ; modified_at = contents.snapshot.modified_at
                     ; records
                     }
                     :: acc)
                    rest))
        in
        (match entries with
         | Error _ as error -> error
         | Ok entries ->
           (match read_summaries [] entries with
            | Error _ as error -> error
            | Ok summaries ->
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
              Ok (List.filteri (fun index _ -> index < limit) ordered))))
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
       (match Fs_compat.load_owned_regular_file ~ownership_root:config.base_path path with
        | Error error ->
          Error
            (Read_failed
               { file
               ; detail = Fs_compat.owned_regular_file_read_error_to_string error
               })
        | Ok None -> Error (No_such_turn file)
        | Ok (Some contents) ->
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
          Ok { file; total_records; offset; records }))
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
