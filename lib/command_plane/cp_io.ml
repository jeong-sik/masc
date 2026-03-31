include Cp_serde

let ensure_dirs config =
  Room_utils.mkdir_p (control_plane_dir config);
  Room_utils.mkdir_p (traces_dir config)

let read_units config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (units_path config)) then
    []
  else
    match Room_utils.read_json_opt config (units_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "units" fields with
        | Some (`List rows) -> List.filter_map unit_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map unit_of_json rows
    | _ -> []

let write_units config units =
  ensure_dirs config;
  Room_utils.write_json config (units_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("units", `List (List.map unit_to_json units));
      ])

let read_operations config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (operations_path config)) then
    []
  else
    match Room_utils.read_json_opt config (operations_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "operations" fields with
        | Some (`List rows) -> List.filter_map operation_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map operation_of_json rows
    | _ -> []

let write_operations config operations =
  ensure_dirs config;
  Room_utils.write_json config (operations_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("operations", `List (List.map operation_to_json operations));
      ])

let read_search_stats config =
  ensure_dirs config;
  Cp_search_fabric.load_store (search_stats_path config)

let write_search_stats config store =
  ensure_dirs config;
  Cp_search_fabric.save_store (search_stats_path config) store

let read_detachments config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (detachments_path config)) then
    []
  else
    match Room_utils.read_json_opt config (detachments_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "detachments" fields with
        | Some (`List rows) -> List.filter_map detachment_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map detachment_of_json rows
    | _ -> []

let write_detachments config detachments =
  ensure_dirs config;
  Room_utils.write_json config (detachments_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("detachments", `List (List.map detachment_to_json detachments));
      ])

let read_policy_decisions config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (decisions_path config)) then
    []
  else
    match Room_utils.read_json_opt config (decisions_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "decisions" fields with
        | Some (`List rows) -> List.filter_map policy_decision_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map policy_decision_of_json rows
    | _ -> []

let write_policy_decisions config decisions =
  ensure_dirs config;
  Room_utils.write_json config (decisions_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("decisions", `List (List.map policy_decision_to_json decisions));
      ])

let read_intents config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (intents_path config)) then
    []
  else
    match Room_utils.read_json_opt config (intents_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "intents" fields with
        | Some (`List rows) -> List.filter_map intent_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map intent_of_json rows
    | _ -> []

let write_intents config intents =
  ensure_dirs config;
  Room_utils.write_json config (intents_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("intents", `List (List.map intent_to_json intents));
      ])

(** Combine byte chunks into a single string, split into non-empty lines,
    and return the last [max_lines]. Shared by both Eio and stdlib paths. *)
let take_last_lines (chunks : Bytes.t list) max_lines =
  let total_bytes =
    List.fold_left (fun acc chunk -> acc + Bytes.length chunk) 0 chunks
  in
  let combined = Bytes.create total_bytes in
  let _ =
    List.fold_left
      (fun offset chunk ->
        let len = Bytes.length chunk in
        Bytes.blit chunk 0 combined offset len;
        offset + len)
      0 chunks
  in
  let all_lines =
    Bytes.to_string combined
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
  in
  let total = List.length all_lines in
  if total <= max_lines then all_lines
  else List.filteri (fun i _ -> i >= total - max_lines) all_lines

(** Read tail chunks backwards from a file opened via Eio.
    Uses [pread_exact] which does not block the Eio scheduler. *)
let read_tail_chunks_eio (file : _ Eio.File.ro) ~file_len ~max_lines =
  let chunk_size = 8192 in
  let target_newlines = max_lines * 3 in
  let chunks = ref [] in
  let total_newlines = ref 0 in
  let pos = ref file_len in
  while !pos > 0 && !total_newlines <= target_newlines do
    let read_start = max 0 (!pos - chunk_size) in
    let read_len = !pos - read_start in
    let buf = Cstruct.create read_len in
    Eio.File.pread_exact file
      ~file_offset:(Optint.Int63.of_int read_start) [buf];
    let bytes = Cstruct.to_bytes buf in
    chunks := bytes :: !chunks;
    for i = 0 to read_len - 1 do
      if Bytes.get bytes i = '\n' then incr total_newlines
    done;
    pos := read_start
  done;
  !chunks

(** Read tail chunks backwards from a file opened via stdlib.
    Falls back to blocking I/O for non-Eio contexts (tests). *)
let read_tail_chunks_stdlib ic ~file_len ~max_lines =
  let chunk_size = 8192 in
  let target_newlines = max_lines * 3 in
  let chunks = ref [] in
  let total_newlines = ref 0 in
  let pos = ref file_len in
  while !pos > 0 && !total_newlines <= target_newlines do
    let read_start = max 0 (!pos - chunk_size) in
    let read_len = !pos - read_start in
    seek_in ic read_start;
    let chunk = Bytes.create read_len in
    really_input ic chunk 0 read_len;
    chunks := chunk :: !chunks;
    for i = 0 to read_len - 1 do
      if Bytes.get chunk i = '\n' then incr total_newlines
    done;
    pos := read_start
  done;
  !chunks

let read_jsonl_tail_lines path ~max_lines =
  if max_lines <= 0 || not (Fs_compat.file_exists path) then
    []
  else
    match Fs_compat.get_fs_opt () with
    | Some fs ->
      (* Eio-native path: non-blocking pread_exact *)
      let eio_path = Eio.Path.(fs / path) in
      Eio.Path.with_open_in eio_path (fun file ->
        let file_len =
          Optint.Int63.to_int (Eio.File.size file)
        in
        if file_len = 0 then []
        else
          let chunks =
            read_tail_chunks_eio file ~file_len ~max_lines
          in
          take_last_lines chunks max_lines)
    | None ->
      (* Stdlib fallback for non-Eio contexts *)
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let file_len = in_channel_length ic in
        if file_len = 0 then []
        else
          let chunks =
            read_tail_chunks_stdlib ic ~file_len ~max_lines
          in
          take_last_lines chunks max_lines)

let read_events ?(max_lines = 500) config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (events_path config)) then
    []
  else
    (* Tail-bounded read to avoid full-file stalls (#4250).
       Previous implementation used load_file which could stall for minutes
       on large event logs. *)
    read_jsonl_tail_lines (events_path config) ~max_lines
    |> List.filter_map (fun line ->
           let trimmed = String.trim line in
           if trimmed = "" then None
           else
             match Safe_ops.parse_json_safe ~context:"command_plane_v2.events" trimmed with
             | Ok json -> event_of_json json
             | Error _ -> None)

let read_recent_events config ~limit =
  ensure_dirs config;
  if not (Room_utils.path_exists config (events_path config)) then
    []
  else
    (* Over-read to compensate for blank/malformed lines lost during filtering *)
    let over_read = max limit (limit * 2) in
    let all =
      read_jsonl_tail_lines (events_path config) ~max_lines:over_read
      |> List.filter_map (fun line ->
             match Safe_ops.parse_json_safe ~context:"command_plane_v2.events" line with
             | Ok json -> event_of_json json
             | Error _ -> None)
    in
    let n = List.length all in
    if n <= limit then all
    else List.filteri (fun i _ -> i >= n - limit) all

let append_event config (event : event_record) =
  ensure_dirs config;
  let path = events_path config in
  Fs_compat.append_jsonl path (event_to_json event)

let next_event_id prefix =
  Printf.sprintf "%s-%s-%04x" prefix
    (Int64.to_string (Int64.of_float (Unix.gettimeofday () *. 1000.0)))
    (Random.bits () land 0xffff)

let next_operation_id () =
  next_event_id "op"

let next_intent_id () =
  next_event_id "intent"

let next_trace_id () =
  next_event_id "trace"
