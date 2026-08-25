(** See [keeper_raw_trace_reader.mli]. *)

type record_census =
  | Whole_file of { records : int }
  | Prefix_only of { budget_bytes : int }

type turn_summary =
  { file : string
  ; trace_id : string option
  ; bytes : int
  ; modified_at : float
  ; census : record_census
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

(* How much of one turn file the listing may read.

   Before this, listing read every file whole and JSON-parsed every line just
   to report a record count, so the cost was O(total bytes in the directory)
   for a page of at most [limit] entries. Measured 2026-08-12 over the 1,229
   retained traces on this host: p50 3.7 KB, p90 60 KB, p95 218 KB — and one
   runaway turn of 372.5 MB (16,801 tool executions in a single turn) holding
   84% of the corpus. That one file made the listing take 3.35 s for one Keeper
   while another keeper with *more* files but less data answered in 0.039 s.

   With a per-file budget the listing costs O(entries x budget) no matter what
   any single turn wrote, and the bound is a property of each file alone —
   whether a file is counted never depends on its neighbours. RFC-0228 §2
   principle 3 states the same rule for the keeper-facing lane pull: paging
   must not reintroduce full-file scans.

   256 KiB was chosen by replaying the same corpus at several budgets: it
   counts 95.2% of turns exactly while the slowest keeper's whole listing costs
   0.092 s. Doubling it buys 2 more points of coverage for 50% more read, and
   the turns it would newly cover are the ones an operator opens anyway. *)
let listing_census_budget_bytes = 256 * 1024

(* A prefix that stopped at the budget ends mid-record. Dropping that partial
   tail keeps the listing from reporting a *torn* line, which would say the
   file is damaged when it is only longer than the budget. *)
let complete_nonblank_lines ~truncated contents =
  let lines = String.split_on_char '\n' contents in
  let lines =
    if not truncated
    then lines
    else (
      match List.rev lines with
      | _partial :: earlier -> List.rev earlier
      | [] -> [])
  in
  List.filter (fun line -> not (String.equal (String.trim line) "")) lines

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
        (* A file the budget covered whole is summarized exactly as before:
           the count is the record count and every record carried one identity.
           A file past the budget reports the identity of its first record and
           says the count was not established here — [read_turn] reads the file
           in full and returns [total_records]. Reporting a prefix's line count
           as the file's would be a wrong number, which is worse than an
           absent one. *)
        let summary_of_prefix ~file (prefix : Fs_compat.owned_regular_file_prefix) =
          if not prefix.truncated
          then
            Result.map
              (fun (records, trace_id) ->
                 { file
                 ; trace_id
                 ; bytes = prefix.file_size
                 ; modified_at = prefix.modified_at
                 ; census = Whole_file { records }
                 })
              (summarize_records ~file prefix.content)
          else (
            let lines = complete_nonblank_lines ~truncated:true prefix.content in
            let first_identity =
              match lines with
              | [] -> Ok None
              | line :: _ ->
                Result.map
                  (fun trace_id -> Some (Keeper_id.Trace_id.to_string trace_id))
                  (trace_id_of_line ~file ~line_number:1 line)
            in
            Result.map
              (fun trace_id ->
                 { file
                 ; trace_id
                 ; bytes = prefix.file_size
                 ; modified_at = prefix.modified_at
                 ; census = Prefix_only { budget_bytes = listing_census_budget_bytes }
                 })
              first_identity)
        in
        let open_prefix ~file ~max_bytes =
          match
            Fs_compat.load_owned_regular_file_prefix
              ~ownership_root:config.base_path
              ~max_bytes
              (Filename.concat dir file)
          with
          | Error error ->
            Error
              (Read_failed
                 { file
                 ; detail = Fs_compat.owned_regular_file_read_error_to_string error
                 })
          | Ok None -> Error (Read_failed { file; detail = "file disappeared during listing" })
          | Ok (Some prefix) -> Ok prefix
        in
        let rec read_summaries acc = function
          | [] -> Ok (List.rev acc)
          | file :: rest ->
            (match open_prefix ~file ~max_bytes:listing_census_budget_bytes with
             | Error _ as error -> error
             | Ok prefix ->
               (match summary_of_prefix ~file prefix with
                | Error _ as error -> error
                | Ok summary -> read_summaries (summary :: acc) rest))
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

(* The census is a sum on the wire, not a nullable count, so a reader has to
   decide what it does about an uncounted turn instead of defaulting one in. *)
let record_census_to_json = function
  | Whole_file { records } ->
    `Assoc [ "state", `String "whole_file"; "records", `Int records ]
  | Prefix_only { budget_bytes } ->
    `Assoc [ "state", `String "prefix_only"; "budget_bytes", `Int budget_bytes ]
;;

let turn_summary_to_json (summary : turn_summary) =
  `Assoc
    [ "file", `String summary.file
    ; "trace_id", Json_util.string_opt_to_json summary.trace_id
    ; "bytes", `Int summary.bytes
    ; "modified_at", `Float summary.modified_at
    ; "census", record_census_to_json summary.census
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
