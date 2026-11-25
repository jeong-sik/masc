(* See the .mli. *)

open Result.Syntax

type root = string

type counts =
  { input_tokens : int
  ; output_tokens : int
  ; cache_read_tokens : int
  ; reasoning_tokens : int
  }

type turn =
  { main : counts
  ; main_cache_write_tokens : int
  ; main_requests : int
  ; last_request_input_tokens : int option
  ; review : counts
  ; reviews : int
  }

type error =
  | Data_root_unavailable
  | Session_id_invalid of string
  | Session_log_not_found of
      { searched : string
      ; session_id : string
      }
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Journal_shrank of
      { path : string
      ; marked_at : int
      ; size : int
      }
  | Slice_too_large of { bytes : int }
  | Unsupported_schema of
      { record : string
      ; found : int
      ; supported : int
      }
  | Malformed_record of
      { byte_offset : int
      ; detail : string
      }
  | No_run_in_slice
  | Run_not_terminated of { run_id : string }

(* A prompt writes its tool results into the journal. This bounds the memory
   one read takes. *)
let max_slice_bytes = 256 * 1024 * 1024
let journal_file_name = "session.jsonl"

(* The versions the record kinds below were read at in muse acp 1.4.25. A
   record at another version may count tokens differently, so it is refused. *)
let envelope_schema_version = 1
let run_payload_schema_version = 1
let approval_payload_schema_version = 3

let error_to_string = function
  | Data_root_unavailable ->
    "neither XDG_DATA_HOME nor HOME is an absolute directory, so the host's data \
     directory is unknown"
  | Session_id_invalid id -> Printf.sprintf "session id %S cannot name a journal directory" id
  | Session_log_not_found { searched; session_id } ->
    Printf.sprintf "no %s for session %s under %s" journal_file_name session_id searched
  | Read_failed { path; detail } -> Printf.sprintf "cannot read %s: %s" path detail
  | Journal_shrank { path; marked_at; size } ->
    Printf.sprintf
      "%s is %d bytes, shorter than the %d bytes it had when the prompt was sent"
      path
      size
      marked_at
  | Slice_too_large { bytes } ->
    Printf.sprintf
      "the prompt added %d bytes to the journal, over the %d byte read limit"
      bytes
      max_slice_bytes
  | Unsupported_schema { record; found; supported } ->
    Printf.sprintf
      "%s has schema version %d, this reader supports %d"
      record
      found
      supported
  | Malformed_record { byte_offset; detail } ->
    Printf.sprintf "journal record at byte %d: %s" byte_offset detail
  | No_run_in_slice -> "the prompt added no run to the journal"
  | Run_not_terminated { run_id } ->
    Printf.sprintf "run %s has no terminal record in the journal yet" run_id
;;

(* ── Where the journal is ─────────────────────────────────────────────────── *)

let env_value env key =
  let prefix = key ^ "=" in
  let prefix_length = String.length prefix in
  Array.find_map
    (fun entry ->
       if String.starts_with ~prefix entry
       then Some (String.sub entry prefix_length (String.length entry - prefix_length))
       else None)
    env
;;

let absolute_env_value env key =
  match env_value env key with
  | Some dir when dir <> "" && not (Filename.is_relative dir) -> Some dir
  | Some _ | None -> None
;;

let root_of_environment env =
  let sessions_under data_home =
    Filename.concat (Filename.concat data_home "muse") "sessions"
  in
  match absolute_env_value env "XDG_DATA_HOME" with
  | Some data_home -> Ok (sessions_under data_home)
  | None ->
    (match absolute_env_value env "HOME" with
     | Some home ->
       Ok (sessions_under (Filename.concat (Filename.concat home ".local") "share"))
     | None -> Error Data_root_unavailable)
;;

let root_directory root = root

let valid_session_id id =
  id <> ""
  && id <> "."
  && id <> ".."
  && String.for_all (fun c -> c <> '/' && c <> '\\' && c <> '\000') id
;;

let is_directory path = try Sys.is_directory path with Sys_error _ -> false

(* The host names its date directories with zero-padded numbers, so the
   reverse of name order is newest first. A Keeper's session is usually the
   newest, and a resumed one stays under the day it was created. *)
let subdirectories_newest_first dir =
  match Sys.readdir dir with
  | names ->
    Array.sort (fun a b -> String.compare b a) names;
    List.filter (fun name -> is_directory (Filename.concat dir name)) (Array.to_list names)
  | exception Sys_error _ -> []
;;

let locate root ~session_id =
  if not (valid_session_id session_id)
  then Error (Session_id_invalid session_id)
  else (
    let journal_in day_directory =
      let path =
        Filename.concat (Filename.concat day_directory session_id) journal_file_name
      in
      if Sys.file_exists path then Some path else None
    in
    let in_each parent find =
      List.find_map
        (fun name -> find (Filename.concat parent name))
        (subdirectories_newest_first parent)
    in
    match in_each root (fun year -> in_each year (fun month -> in_each month journal_in)) with
    | Some path -> Ok path
    | None -> Error (Session_log_not_found { searched = root; session_id }))
;;

type mark =
  { path : string
  ; offset : int
  }

let mark root ~session_id =
  let* path = locate root ~session_id in
  match Unix.stat path with
  | stats -> Ok { path; offset = stats.Unix.st_size }
  | exception Unix.Unix_error (err, _, _) ->
    Error (Read_failed { path; detail = Unix.error_message err })
;;

(* ── What the prompt added ────────────────────────────────────────────────── *)

(* Returns the file offset of the first byte read and the bytes up to the end
   of the file as it is now. One byte before the mark is read as well: it
   tells whether the mark fell between two records. *)
let read_slice { path; offset } =
  let read ic =
    let size = Int64.to_int (In_channel.length ic) in
    if size < offset
    then Error (Journal_shrank { path; marked_at = offset; size })
    else if size - offset > max_slice_bytes
    then Error (Slice_too_large { bytes = size - offset })
    else (
      let start = max 0 (offset - 1) in
      In_channel.seek ic (Int64.of_int start);
      match In_channel.really_input_string ic (size - start) with
      | Some slice -> Ok (start, slice)
      | None ->
        Error
          (Read_failed { path; detail = "the file ended before the length it had when read" }))
  in
  match In_channel.with_open_bin path read with
  | result -> result
  | exception Sys_error detail -> Error (Read_failed { path; detail })
;;

(* The newline-terminated lines of [slice] that begin at or after [offset],
   each with the file offset it begins at. [start] is the file offset of
   [slice.[0]]. A line the host was still writing when [slice] was read has no
   newline yet and is left out. When [offset > 0], [slice.[0]] is the byte
   before the mark: a newline there means the mark fell between two records;
   anything else means it fell inside one, which the host wrote for earlier
   activity, so that record's remaining bytes are skipped. *)
let complete_lines ~start ~offset slice =
  let first_line =
    if offset = 0
    then Some 0
    else if slice.[0] = '\n'
    then Some 1
    else Option.map (fun newline -> newline + 1) (String.index_from_opt slice 1 '\n')
  in
  let rec from position found =
    match String.index_from_opt slice position '\n' with
    | Some newline ->
      from
        (newline + 1)
        ((start + position, String.sub slice position (newline - position)) :: found)
    | None -> List.rev found
  in
  match first_line with
  | Some position -> from position []
  | None -> []
;;

type record =
  | Run_started of { run_id : string }
  | Run_terminal of { run_id : string }
  | Model_completed of
      { run_id : string
      ; counts : counts
      ; cache_write_tokens : int
      }
  | Review_completed of
      { run_id : string
      ; counts : counts
      }

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_field key json =
  match assoc_field key json with
  | Some (`String s) -> Some s
  | _ -> None
;;

let count_field usage key =
  match assoc_field key usage with
  | Some (`Int n) when n >= 0 -> Ok n
  | Some _ -> Error (Printf.sprintf "usage.%s is not a non-negative integer" key)
  | None -> Error (Printf.sprintf "usage.%s is missing" key)
;;

(* [counts] means input includes the cached tokens and output includes the
   reasoning tokens. A record that contradicts it was written under another
   accounting, and summing it as if it were this one would miscount. *)
let check_inclusive counts =
  if counts.cache_read_tokens > counts.input_tokens
  then Error "cache_read_tokens is larger than input_tokens, which counts the cached tokens"
  else if counts.reasoning_tokens > counts.output_tokens
  then Error "reasoning_tokens is larger than output_tokens, which counts the reasoning tokens"
  else Ok counts
;;

let main_counts usage =
  let* input_tokens = count_field usage "input_tokens" in
  let* output_tokens = count_field usage "output_tokens" in
  let* cache_read_tokens = count_field usage "cache_read_tokens" in
  let* cache_write_tokens = count_field usage "cache_write_tokens" in
  let* reasoning_tokens = count_field usage "reasoning_tokens" in
  let* counts =
    check_inclusive { input_tokens; output_tokens; cache_read_tokens; reasoning_tokens }
  in
  Ok (counts, cache_write_tokens)
;;

let review_counts usage =
  let* input_tokens = count_field usage "input_tokens" in
  let* output_tokens = count_field usage "output_tokens" in
  let* cache_read_tokens = count_field usage "cached_input_tokens" in
  let* reasoning_tokens = count_field usage "reasoning_tokens" in
  check_inclusive { input_tokens; output_tokens; cache_read_tokens; reasoning_tokens }
;;

(* [None] for every record kind this module does not count. Only the four it
   counts are held to a schema version. *)
let decode_record ~byte_offset json =
  let malformed detail = Error (Malformed_record { byte_offset; detail }) in
  let check_schema ~record ~payload_version =
    let version key =
      match assoc_field key json with
      | Some (`Int n) -> Ok n
      | Some _ | None -> malformed (key ^ " is missing or not an integer")
    in
    let* envelope = version "schema_version" in
    let* payload = version "payload_schema_version" in
    if envelope <> envelope_schema_version
    then
      Error
        (Unsupported_schema
           { record = record ^ " envelope"
           ; found = envelope
           ; supported = envelope_schema_version
           })
    else if payload <> payload_version
    then
      Error (Unsupported_schema { record; found = payload; supported = payload_version })
    else Ok ()
  in
  let run_id payload =
    match string_field "run_id" payload with
    | Some id -> Ok id
    | None -> malformed "run_id is missing"
  in
  let usage_of event decode =
    match assoc_field "usage" event with
    | Some (`Assoc _ as usage) ->
      Result.map_error (fun detail -> Malformed_record { byte_offset; detail }) (decode usage)
    | Some _ | None -> malformed "usage is missing or not an object"
  in
  match assoc_field "payload" json with
  | Some (`Assoc _ as payload) ->
    let event = Option.value (assoc_field "event" payload) ~default:`Null in
    (match string_field "kind" payload, string_field "kind" event with
     | Some "run", Some "started" ->
       let* () =
         check_schema ~record:"run/started" ~payload_version:run_payload_schema_version
       in
       let* run_id = run_id payload in
       Ok (Some (Run_started { run_id }))
     | Some "run", Some "terminal" ->
       let* () =
         check_schema ~record:"run/terminal" ~payload_version:run_payload_schema_version
       in
       let* run_id = run_id payload in
       Ok (Some (Run_terminal { run_id }))
     | Some "run", Some "model_completed" ->
       let* () =
         check_schema
           ~record:"run/model_completed"
           ~payload_version:run_payload_schema_version
       in
       let* run_id = run_id payload in
       let* counts, cache_write_tokens = usage_of event main_counts in
       Ok (Some (Model_completed { run_id; counts; cache_write_tokens }))
     | Some "approval", Some "automated_review_completed" ->
       let* () =
         check_schema
           ~record:"approval/automated_review_completed"
           ~payload_version:approval_payload_schema_version
       in
       let* run_id = run_id payload in
       let* counts = usage_of event review_counts in
       Ok (Some (Review_completed { run_id; counts }))
     | _ -> Ok None)
  | Some _ | None -> Ok None
;;

let decode_lines lines =
  List.fold_left
    (fun records (byte_offset, line) ->
       let* records = records in
       if line = ""
       then Ok records
       else (
         match Yojson.Safe.from_string line with
         | exception Yojson.Json_error detail ->
           Error (Malformed_record { byte_offset; detail })
         | json ->
           let* decoded = decode_record ~byte_offset json in
           Ok
             (match decoded with
              | Some record -> record :: records
              | None -> records)))
    (Ok [])
    lines
  |> Result.map List.rev
;;

let zero_counts =
  { input_tokens = 0; output_tokens = 0; cache_read_tokens = 0; reasoning_tokens = 0 }
;;

let add_counts a b =
  { input_tokens = a.input_tokens + b.input_tokens
  ; output_tokens = a.output_tokens + b.output_tokens
  ; cache_read_tokens = a.cache_read_tokens + b.cache_read_tokens
  ; reasoning_tokens = a.reasoning_tokens + b.reasoning_tokens
  }
;;

let total turn = add_counts turn.main turn.review

let no_counts =
  { main = zero_counts
  ; main_cache_write_tokens = 0
  ; main_requests = 0
  ; last_request_input_tokens = None
  ; review = zero_counts
  ; reviews = 0
  }
;;

(* The prompt's runs are the ones whose [started] record is in the slice. A
   record of another run in the slice, such as the tail of the previous
   prompt's, is not the prompt's. *)
let summarize records =
  let started =
    List.filter_map
      (function
        | Run_started { run_id } -> Some run_id
        | Run_terminal _ | Model_completed _ | Review_completed _ -> None)
      records
    |> List.sort_uniq String.compare
  in
  let terminated =
    List.filter_map
      (function
        | Run_terminal { run_id } -> Some run_id
        | Run_started _ | Model_completed _ | Review_completed _ -> None)
      records
  in
  match started with
  | [] -> Error No_run_in_slice
  | _ :: _ ->
    (match List.find_opt (fun run_id -> not (List.mem run_id terminated)) started with
     | Some run_id -> Error (Run_not_terminated { run_id })
     | None ->
       Ok
         (List.fold_left
            (fun turn record ->
               match record with
               | Model_completed { run_id; counts; cache_write_tokens }
                 when List.mem run_id started ->
                 { turn with
                   main = add_counts turn.main counts
                 ; main_cache_write_tokens =
                     turn.main_cache_write_tokens + cache_write_tokens
                 ; main_requests = turn.main_requests + 1
                 ; last_request_input_tokens = Some counts.input_tokens
                 }
               | Review_completed { run_id; counts } when List.mem run_id started ->
                 { turn with
                   review = add_counts turn.review counts
                 ; reviews = turn.reviews + 1
                 }
               | Model_completed _ | Review_completed _ | Run_started _ | Run_terminal _ ->
                 turn)
            no_counts
            records))
;;

let read_turn m =
  let* start, slice = read_slice m in
  let* records = decode_lines (complete_lines ~start ~offset:m.offset slice) in
  summarize records
;;
