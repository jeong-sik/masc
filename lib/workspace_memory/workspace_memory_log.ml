type batch_id = string
type seq = int

type batch_header = {
  batch_id : batch_id;
  author : string;
  started_at : string;
  expected_changes : int;
}

type change_entry = {
  seq : seq;
  batch_id : batch_id;
  fact_id : string;
  summary : string;
  payload : Yojson.Safe.t;
  recorded_at : string;
}

type log_record =
  | Prepared of batch_header
  | Change of change_entry
  | Committed of { batch_id : batch_id; committed_at : string; final_seq : seq }
  | Aborted of { batch_id : batch_id; aborted_at : string; reason : string }

type error =
  | Unknown_record_kind of string
  | Missing_field of string
  | Invalid_field of { field : string; detail : string }
  | Malformed_json of string
  | Io_error of string
  | Invalid_batch of string

type recovery_report = {
  committed_changes : change_entry list;
  incomplete_batches : batch_header list;
  aborted_batches : batch_id list;
  last_committed_seq : seq;
}

open Result.Syntax

let error_to_string = function
  | Unknown_record_kind kind ->
    Printf.sprintf "unknown_record_kind(%s)" kind
  | Missing_field field ->
    Printf.sprintf "missing_field(%s)" field
  | Invalid_field { field; detail } ->
    Printf.sprintf "invalid_field(%s: %s)" field detail
  | Malformed_json detail ->
    Printf.sprintf "malformed_json(%s)" detail
  | Io_error detail ->
    Printf.sprintf "io_error(%s)" detail
  | Invalid_batch detail ->
    Printf.sprintf "invalid_batch(%s)" detail

type record_kind =
  | Kind_prepared
  | Kind_change
  | Kind_committed
  | Kind_aborted

let kind_wire_pairs =
  [ "prepared", Kind_prepared
  ; "change", Kind_change
  ; "committed", Kind_committed
  ; "aborted", Kind_aborted
  ]

let kind_to_wire = function
  | Kind_prepared -> "prepared"
  | Kind_change -> "change"
  | Kind_committed -> "committed"
  | Kind_aborted -> "aborted"

let kind_of_wire raw =
  match List.assoc_opt raw kind_wire_pairs with
  | Some kind -> Ok kind
  | None -> Error (Unknown_record_kind raw)

let record_to_yojson = function
  | Prepared { batch_id; author; started_at; expected_changes } ->
    `Assoc
      [ "kind", `String (kind_to_wire Kind_prepared)
      ; "batch_id", `String batch_id
      ; "author", `String author
      ; "started_at", `String started_at
      ; "expected_changes", `Int expected_changes
      ]
  | Change { seq; batch_id; fact_id; summary; payload; recorded_at } ->
    `Assoc
      [ "kind", `String (kind_to_wire Kind_change)
      ; "seq", `Int seq
      ; "batch_id", `String batch_id
      ; "fact_id", `String fact_id
      ; "summary", `String summary
      ; "payload", payload
      ; "recorded_at", `String recorded_at
      ]
  | Committed { batch_id; committed_at; final_seq } ->
    `Assoc
      [ "kind", `String (kind_to_wire Kind_committed)
      ; "batch_id", `String batch_id
      ; "committed_at", `String committed_at
      ; "final_seq", `Int final_seq
      ]
  | Aborted { batch_id; aborted_at; reason } ->
    `Assoc
      [ "kind", `String (kind_to_wire Kind_aborted)
      ; "batch_id", `String batch_id
      ; "aborted_at", `String aborted_at
      ; "reason", `String reason
      ]

let require_object = function
  | `Assoc fields -> Ok fields
  | _ ->
    Error
      (Invalid_field
         { field = "record"; detail = "log record must be a JSON object" })

let require_field field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Missing_field field)

let has_newline text =
  String.exists (fun ch -> Char.equal ch '\n' || Char.equal ch '\r') text

let require_nonblank_string ~allow_newline field fields =
  let* value = require_field field fields in
  match value with
  | `String s ->
    if String.equal (String.trim s) "" then
      Error (Invalid_field { field; detail = "must be a non-blank string" })
    else if (not allow_newline) && has_newline s then
      Error
        (Invalid_field { field; detail = "must be a single line without newlines" })
    else
      Ok s
  | _ ->
    Error (Invalid_field { field; detail = "expected string" })

let require_int ~min_value field fields =
  let* value = require_field field fields in
  match value with
  | `Int n ->
    if n < min_value then
      Error
        (Invalid_field
           { field
           ; detail = Printf.sprintf "must be >= %d (got %d)" min_value n
           })
    else
      Ok n
  | _ ->
    Error (Invalid_field { field; detail = "expected integer" })

let decode_prepared fields =
  let* batch_id =
    require_nonblank_string ~allow_newline:false "batch_id" fields
  in
  let* author =
    require_nonblank_string ~allow_newline:false "author" fields
  in
  let* started_at =
    require_nonblank_string ~allow_newline:false "started_at" fields
  in
  let* expected_changes =
    require_int ~min_value:0 "expected_changes" fields
  in
  Ok (Prepared { batch_id; author; started_at; expected_changes })

let decode_change fields =
  let* seq = require_int ~min_value:1 "seq" fields in
  let* batch_id =
    require_nonblank_string ~allow_newline:false "batch_id" fields
  in
  let* fact_id =
    require_nonblank_string ~allow_newline:false "fact_id" fields
  in
  let* summary =
    require_nonblank_string ~allow_newline:false "summary" fields
  in
  let* payload = require_field "payload" fields in
  let* recorded_at =
    require_nonblank_string ~allow_newline:false "recorded_at" fields
  in
  Ok (Change { seq; batch_id; fact_id; summary; payload; recorded_at })

let decode_committed fields =
  let* batch_id =
    require_nonblank_string ~allow_newline:false "batch_id" fields
  in
  let* committed_at =
    require_nonblank_string ~allow_newline:false "committed_at" fields
  in
  let* final_seq = require_int ~min_value:0 "final_seq" fields in
  Ok (Committed { batch_id; committed_at; final_seq })

let decode_aborted fields =
  let* batch_id =
    require_nonblank_string ~allow_newline:false "batch_id" fields
  in
  let* aborted_at =
    require_nonblank_string ~allow_newline:false "aborted_at" fields
  in
  let* reason =
    require_nonblank_string ~allow_newline:false "reason" fields
  in
  Ok (Aborted { batch_id; aborted_at; reason })

let record_of_yojson json =
  let* fields = require_object json in
  let* raw_kind =
    require_nonblank_string ~allow_newline:false "kind" fields
  in
  let* kind = kind_of_wire raw_kind in
  match kind with
  | Kind_prepared -> decode_prepared fields
  | Kind_change -> decode_change fields
  | Kind_committed -> decode_committed fields
  | Kind_aborted -> decode_aborted fields

let record_to_json_line record =
  Yojson.Safe.to_string (record_to_yojson record)

let record_of_json_line line =
  let* json =
    try Ok (Yojson.Safe.from_string line) with
    | Yojson.Json_error detail -> Error (Malformed_json detail)
  in
  record_of_yojson json

module String_map = Map.Make (String)

type batch_lifecycle =
  | In_flight of { header : batch_header; rev_changes : change_entry list }
  | Batch_committed of
      { header : batch_header
      ; changes : change_entry list
      ; final_seq : seq
      }
  | Batch_aborted of { batch_id : batch_id }

let changes_are_monotonic ~after_seq (changes : change_entry list) =
  let rec loop prev = function
    | [] -> true
    | (entry : change_entry) :: rest ->
      if entry.seq <= prev then false else loop entry.seq rest
  in
  loop after_seq changes

let batch_matches_commit
    ~last_committed_seq
    ~(header : batch_header)
    ~(changes : change_entry list)
    ~final_seq =
  let count = List.length changes in
  if count <> header.expected_changes then
    false
  else if not (changes_are_monotonic ~after_seq:last_committed_seq changes) then
    false
  else
    match List.rev changes with
    | [] -> final_seq = last_committed_seq
    | last :: _ -> last.seq = final_seq

let add_unique_batch_id (id : batch_id) (acc : batch_id list) =
  if List.exists (String.equal id) acc then acc else id :: acc

let recover (records : log_record list) : recovery_report =
  let batches, prepared_order_rev, committed_groups_rev, aborted_rev, last_seq =
    List.fold_left
      (fun (batches, order_rev, committed_rev, aborted_rev, last_seq) record ->
         match record with
         | Prepared header ->
           (match String_map.find_opt header.batch_id batches with
            | Some (Batch_committed _ | Batch_aborted _) ->
              batches, order_rev, committed_rev, aborted_rev, last_seq
            | Some (In_flight _) | None ->
              let batches =
                String_map.add
                  header.batch_id
                  (In_flight { header; rev_changes = [] })
                  batches
              in
              let order_rev =
                add_unique_batch_id header.batch_id order_rev
              in
              batches, order_rev, committed_rev, aborted_rev, last_seq)
         | Change entry ->
           (match String_map.find_opt entry.batch_id batches with
            | Some (In_flight { header; rev_changes }) ->
              let batches =
                String_map.add
                  entry.batch_id
                  (In_flight { header; rev_changes = entry :: rev_changes })
                  batches
              in
              batches, order_rev, committed_rev, aborted_rev, last_seq
            | Some (Batch_committed _ | Batch_aborted _) | None ->
              batches, order_rev, committed_rev, aborted_rev, last_seq)
         | Committed { batch_id; committed_at = _; final_seq } ->
           (match String_map.find_opt batch_id batches with
            | Some (In_flight { header; rev_changes }) ->
              let changes = List.rev rev_changes in
              if
                batch_matches_commit
                  ~last_committed_seq:last_seq
                  ~header
                  ~changes
                  ~final_seq
              then
                let batches =
                  String_map.add
                    batch_id
                    (Batch_committed { header; changes; final_seq })
                    batches
                in
                let next_last_seq = Int.max last_seq final_seq in
                ( batches
                , order_rev
                , changes :: committed_rev
                , aborted_rev
                , next_last_seq )
              else
                batches, order_rev, committed_rev, aborted_rev, last_seq
            | Some (Batch_committed _ | Batch_aborted _) | None ->
              batches, order_rev, committed_rev, aborted_rev, last_seq)
         | Aborted { batch_id; aborted_at = _; reason = _ } ->
           (match String_map.find_opt batch_id batches with
            | Some (Batch_committed _) ->
              batches, order_rev, committed_rev, aborted_rev, last_seq
            | Some (In_flight _ | Batch_aborted _) | None ->
              let batches =
                String_map.add batch_id (Batch_aborted { batch_id }) batches
              in
              let aborted_rev = add_unique_batch_id batch_id aborted_rev in
              batches, order_rev, committed_rev, aborted_rev, last_seq))
      (String_map.empty, [], [], [], 0)
      records
  in
  let prepared_order = List.rev prepared_order_rev in
  let incomplete_batches =
    List.filter_map
      (fun batch_id ->
         match String_map.find_opt batch_id batches with
         | Some (In_flight { header; _ }) -> Some header
         | Some (Batch_committed _ | Batch_aborted _) | None -> None)
      prepared_order
  in
  let committed_changes = List.concat (List.rev committed_groups_rev) in
  { committed_changes
  ; incomplete_batches
  ; aborted_batches = List.rev aborted_rev
  ; last_committed_seq = last_seq
  }

let log_path ~base_path =
  Filename.concat
    (Workspace_memory_ledger.directory ~base_path)
    "log.jsonl"

let io f =
  try f () with
  | Unix.Unix_error (error, fn, arg) ->
    Error
      (Io_error
         (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error)))
  | Sys_error detail -> Error (Io_error detail)
  | Eio.Io _ as exn -> Error (Io_error (Printexc.to_string exn))

let with_log_lock ~path f =
  let* () =
    io (fun () ->
      Fs_compat.mkdir_p (Filename.dirname path);
      Ok ())
  in
  match File_lock_eio.with_durable_lock ~lock_path:(path ^ ".lock") f with
  | Ok result -> result
  | Error lock_err ->
    Error (Io_error (File_lock_eio.durable_lock_error_to_string lock_err))

let truncate_incomplete_tail_unlocked ~path =
  match Fs_compat.load_file_opt path with
  | None -> ()
  | Some content ->
    let len = String.length content in
    if len > 0 && not (Char.equal content.[len - 1] '\n') then
      let clean_len =
        match String.rindex_opt content '\n' with
        | Some idx -> idx + 1
        | None -> 0
      in
      Unix.truncate path clean_len

let append_record_unlocked ~path record =
  io (fun () ->
    Fs_compat.mkdir_p (Filename.dirname path);
    truncate_incomplete_tail_unlocked ~path;
    let line = record_to_json_line record ^ "\n" in
    Fs_compat.append_file path line;
    Ok ())

let append_record ~path record =
  with_log_lock ~path (fun () -> append_record_unlocked ~path record)

let load_log_unlocked ~path =
  io (fun () ->
    match Fs_compat.load_file_opt path with
    | None -> Ok []
    | Some content ->
      let raw_lines = String.split_on_char '\n' content in
      (* Every committed or prepared JSONL record is written with a trailing
         '\n'. The element after the last '\n' is "" on a cleanly terminated
         file, or a cut-off partial record when a crash interrupted an append.
         Drop that trailing element so a mid-append crash leaves the batch
         in-flight rather than bricking the log, while keeping strict decoding
         for all complete lines. *)
      let complete_lines =
        match List.rev raw_lines with
        | [] -> []
        | _trailing_after_last_newline :: rev_complete -> List.rev rev_complete
      in
      let non_empty_lines =
        List.filter
          (fun line -> not (String.equal (String.trim line) ""))
          complete_lines
      in
      let rec decode_all acc = function
        | [] -> Ok (List.rev acc)
        | line :: rest ->
          let* record = record_of_json_line line in
          decode_all (record :: acc) rest
      in
      decode_all [] non_empty_lines)

let load_log ~path = load_log_unlocked ~path

let batch_id_in_record batch_id = function
  | Prepared h -> String.equal h.batch_id batch_id
  | Change e -> String.equal e.batch_id batch_id
  | Committed { batch_id = id; _ } | Aborted { batch_id = id; _ } ->
    String.equal id batch_id

let validate_batch
    ~after_seq
    ~(header : batch_header)
    ~(changes : change_entry list) =
  let count = List.length changes in
  if String.equal (String.trim header.batch_id) "" then
    Error (Invalid_batch "batch_id must be non-blank")
  else if header.expected_changes < 0 then
    Error (Invalid_batch "expected_changes must be non-negative")
  else if count <> header.expected_changes then
    Error
      (Invalid_batch
         (Printf.sprintf
            "expected %d changes for batch %s, got %d"
            header.expected_changes
            header.batch_id
            count))
  else
    let rec check_entries prev_seq = function
      | [] -> Ok prev_seq
      | (entry : change_entry) :: rest ->
        if not (String.equal entry.batch_id header.batch_id) then
          Error
            (Invalid_batch
               (Printf.sprintf
                  "change seq %d has batch_id %s, expected %s"
                  entry.seq
                  entry.batch_id
                  header.batch_id))
        else if entry.seq <= prev_seq then
          Error
            (Invalid_batch
               (Printf.sprintf
                  "change seq %d must be strictly greater than %d"
                  entry.seq
                  prev_seq))
        else
          check_entries entry.seq rest
    in
    check_entries after_seq changes

let append_batch
    ~path
    ~(header : batch_header)
    ~(changes : change_entry list)
    ~committed_at =
  with_log_lock ~path (fun () ->
    let* existing_records = load_log_unlocked ~path in
    if List.exists (batch_id_in_record header.batch_id) existing_records then
      Error
        (Invalid_batch
           (Printf.sprintf "batch_id %s already exists in log" header.batch_id))
    else
      let existing_report = recover existing_records in
      let* final_seq =
        validate_batch
          ~after_seq:existing_report.last_committed_seq
          ~header
          ~changes
      in
      let records =
        Prepared header
        :: List.map (fun entry -> Change entry) changes
        @ [ Committed { batch_id = header.batch_id; committed_at; final_seq } ]
      in
      io (fun () ->
        Fs_compat.mkdir_p (Filename.dirname path);
        truncate_incomplete_tail_unlocked ~path;
        let payload =
          String.concat "\n" (List.map record_to_json_line records) ^ "\n"
        in
        Fs_compat.append_file path payload;
        Ok final_seq))

let abort_incomplete_batches ~path ~aborted_at ~reason (report : recovery_report) =
  with_log_lock ~path (fun () ->
    let rec append_all acc_aborted = function
      | [] ->
        Ok
          { report with
            incomplete_batches = []
          ; aborted_batches = List.rev acc_aborted
          }
      | (header : batch_header) :: rest ->
        let record =
          Aborted { batch_id = header.batch_id; aborted_at; reason }
        in
        let* () = append_record_unlocked ~path record in
        let next_aborted =
          add_unique_batch_id header.batch_id acc_aborted
        in
        append_all next_aborted rest
    in
    append_all (List.rev report.aborted_batches) report.incomplete_batches)

let recover_file ~path =
  let* records = load_log ~path in
  Ok (recover records)
