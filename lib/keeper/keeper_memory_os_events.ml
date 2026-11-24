(* Memory history events. See the interface for the contract. *)

module W = Keeper_memory_os_types

let ( let* ) = Result.bind
let ( let+ ) r f = Result.map f r
let suffix = ".memory-events.jsonl"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

type event_kind = Retrieved of { query : string }

type event =
  { recorded_at : float
  ; memory_id : string
  ; trace_id : string
  ; kind : event_kind
  }

let field_recorded_at = "recorded_at"
let field_memory_id = "memory_id"
let field_trace_id = "trace_id"
let field_kind = "kind"
let field_query = "query"
let kind_retrieved = "retrieved"
let common_fields = [ field_recorded_at; field_memory_id; field_trace_id; field_kind ]

let kind_token = function
  | Retrieved _ -> kind_retrieved
;;

let payload = function
  | Retrieved { query } -> [ field_query, `String query ]
;;

let event_to_json (e : event) : Yojson.Safe.t =
  `Assoc
    ([ field_recorded_at, `Float e.recorded_at
    ; field_memory_id, `String e.memory_id
    ; field_trace_id, `String e.trace_id
    ; field_kind, `String (kind_token e.kind)
    ] @ payload e.kind)
;;

let non_blank s = not (String.equal (String.trim s) "")

(* Shared by the decoder and [append], so a row this module wrote is a row this
   module reads back. *)
let validate (e : event) : (event, W.wire_error) result =
  let* () =
    if Float.is_finite e.recorded_at
    then Ok ()
    else W.wire_fail [ W.Wire_field field_recorded_at ] W.Not_finite
  in
  let* () =
    if W.is_memory_id e.memory_id
    then Ok ()
    else W.wire_fail [ W.Wire_field field_memory_id ] (W.Not_a_memory_id e.memory_id)
  in
  let+ () =
    match e.kind with
    | Retrieved { query } ->
      if non_blank query
      then Ok ()
      else W.wire_fail [ W.Wire_field field_query ] W.Blank_string
  in
  e
;;

let kind_of_token token =
  match token with
  | "retrieved" ->
    Ok ([ field_query ], fun fields ->
      let+ query = W.wire_string_field field_query fields in Retrieved { query })
  | unknown -> W.wire_fail [ W.Wire_field field_kind ] (W.Unknown_token unknown)
;;

let event_of_json (json : Yojson.Safe.t) : (event, W.wire_error) result =
  match json with
  | `Assoc fields ->
    let* token = W.wire_string_field field_kind fields in
    let* payload_fields, read_kind = kind_of_token token in
    let* () = W.exact_field_names_result (common_fields @ payload_fields) fields in
    let* recorded_at = W.wire_number_field field_recorded_at fields in
    let* memory_id = W.wire_string_field field_memory_id fields in
    let* trace_id = W.wire_string_field field_trace_id fields in
    let* kind = read_kind fields in
    validate { recorded_at; memory_id; trace_id; kind }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    W.wire_here W.Expected_object
;;

type append_error =
  | Invalid_event of W.wire_error
  | Write_failed of
      { path : string
      ; message : string
      }

let append_error_to_string = function
  | Invalid_event error -> "memory event rejected: " ^ W.wire_error_to_string error
  | Write_failed { path; message } ->
    Printf.sprintf "memory event append failed path=%s: %s" path message
;;

(* A row a crash cut short has no newline. The locked durable append cuts it
   off before writing, so the next event starts its own line instead of
   joining the torn one and making both unreadable. All the lines go in one
   transaction: one lock, one fsync of the file, one of its directory. *)
let write_events ~keepers_dir ~keeper_id (events : event list) : (unit, append_error) result =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let suffix =
    String.concat ""
      (List.map (fun e -> Yojson.Safe.to_string (event_to_json e) ^ "\n") events)
  in
  let failed message = Error (Write_failed { path; message }) in
  match Fs_compat.append_private_jsonl_durable_locked_result path suffix with
  | Fs_compat.Private_file_succeeded () -> Ok ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
    Log.Keeper.warn
      ~keeper_name:keeper_id
      "memory event append committed; descriptor settlement failed path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    Ok ()
  | Fs_compat.Private_file_failed error ->
    failed (Fs_compat.private_jsonl_append_error_to_string error)
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    failed
      (Printf.sprintf
         "%s; descriptor settlement also failed: %s"
         (Fs_compat.private_jsonl_append_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> failed (Printexc.to_string exn)
;;

let append ~keepers_dir ~keeper_id (e : event) : (unit, append_error) result =
  match validate e with
  | Error error -> Error (Invalid_event error)
  | Ok e -> write_events ~keepers_dir ~keeper_id [ e ]
;;

(* Reject the events that fail validation, then write the rest in one append.
   A producer on a path that must not fail (a search returning its results)
   reports what comes back in its log and goes on. *)
let append_all ~keepers_dir ~keeper_id (events : event list) : append_error list =
  let rejected, valid =
    List.partition_map
      (fun event ->
         match validate event with
         | Error error -> Either.Left (Invalid_event error)
         | Ok event -> Either.Right event)
      events
  in
  match valid with
  | [] -> rejected
  | _ :: _ ->
    (match write_events ~keepers_dir ~keeper_id valid with
     | Ok () -> rejected
     | Error error -> rejected @ [ error ])
;;

type read_error =
  | Not_json of string
  | Malformed of W.wire_error

type file_read_error =
  { path : string
  ; message : string
  }

let read_error_to_string = function
  | Not_json message -> "memory event line is not valid JSON: " ^ message
  | Malformed error -> "memory event line rejected: " ^ W.wire_error_to_string error
;;

let file_read_error_to_string (error : file_read_error) =
  Printf.sprintf "memory event sidecar read failed path=%s: %s" error.path error.message
;;

let decode_line line =
  match Yojson.Safe.from_string line with
  | json -> Result.map_error (fun e -> Malformed e) (event_of_json json)
  | exception Yojson.Json_error message -> Error (Not_json message)
;;

let fold ~keepers_dir ~keeper_id ~init ~f =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  let row acc raw = if non_blank raw then f acc (decode_line raw) else acc in
  let error message = Error { path; message } in
  match Fs_compat.fold_private_jsonl_locked_result path ~init ~f:row with
  | Fs_compat.Private_file_failed e | Private_file_failed_with_cleanup_failure { error = e; _ } ->
    (match e with
     | Fs_compat.Private_jsonl_fold.Read_error err -> error (Fs_compat.Private_jsonl_rows.error_to_string err)
     | Snapshot_changed -> error "retrieval sidecar changed during observation")
  | Private_file_succeeded r | Private_file_succeeded_with_cleanup_failure { value = r; _ } ->
    (match r with
     | Fs_compat.Private_jsonl_fold.Missing -> Ok init
     | Present { value; rows_end; end_offset } when rows_end = end_offset -> Ok value
     | Present { value; rows_end; end_offset } ->
       (* [read] also decodes a final unterminated row. A concurrent append must
          not turn a prefix of the new row into an event from this observation. *)
       let length = end_offset - rows_end in
       match Fs_compat.load_owned_regular_file_range ~ownership_root:keepers_dir
               ~offset:rows_end ~max_bytes:length path with
       | Ok (Some tail) when tail.snapshot.file_size = end_offset && String.length tail.content = length
                             && not (String.contains tail.content '\n') -> Ok (row value tail.content)
       | Ok _ -> error "retrieval sidecar changed during observation"
       | Error e -> error (Fs_compat.owned_regular_file_read_error_to_string e))
;;

let read ~keepers_dir ~keeper_id :
    ((int * (event, read_error) result) list, file_read_error) result =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | exception Sys_error message -> Error { path; message }
  | None -> Ok []
  | Some contents ->
    Ok (String.split_on_char '\n' contents |> List.filter non_blank
        |> List.mapi (fun index line -> index, decode_line line))
;;

type summary =
  { retrieved_count : int
  ; retrieved_distinct_days : int
  ; last_retrieved_at : float option
  ; retracted_count : int
  ; revised_from : string list
  }

let seconds_per_day = 86_400.
let utc_day recorded_at = int_of_float (Float.floor (recorded_at /. seconds_per_day))

module Memory_id_map = Map.Make (String)
module Memory_id_set = Set.Make (String)
module Day_set = Set.Make (Int)

type summary_accumulator =
  { retrievals : int
  ; days : Day_set.t
  ; latest : float option
  }

let empty_accumulator = { retrievals = 0; days = Day_set.empty; latest = None }

let summaries_for ~memory_ids ~(revisions : W.revision list) ~retractions
    (events : event list) : summary list =
  match memory_ids with
  | [] -> []
  | _ :: _ ->
  let requested = List.fold_left (fun summaries memory_id ->
    Memory_id_map.add memory_id empty_accumulator summaries)
      Memory_id_map.empty memory_ids in
  let retrievals =
    List.fold_left
      (fun summaries (event : event) ->
         match Memory_id_map.find_opt event.memory_id summaries with
         | None -> summaries
         | Some current ->
           match event.kind with
           | Retrieved _ ->
             Memory_id_map.add event.memory_id
               { retrievals = current.retrievals + 1
               ; days = Day_set.add (utc_day event.recorded_at) current.days
               ; latest = Some (match current.latest with
                   | None -> event.recorded_at
                   | Some seen -> Float.max seen event.recorded_at)
               } summaries)
      requested events
  in
  let retracted_count memory_id =
    List.length (List.filter (String.equal memory_id) retractions)
  in
  let revised_from memory_id =
    List.filter_map
      (fun (link : W.revision) ->
         if String.equal link.superseded_by memory_id
            && not (String.equal link.superseded memory_id)
         then Some link.superseded
         else None)
      revisions
    |> Memory_id_set.of_list
    |> Memory_id_set.elements
  in
  List.map
    (fun memory_id ->
       let current = Memory_id_map.find memory_id retrievals in
       { retrieved_count = current.retrievals
       ; retrieved_distinct_days = Day_set.cardinal current.days
       ; last_retrieved_at = current.latest
       ; retracted_count = retracted_count memory_id
       ; revised_from = revised_from memory_id
       })
    memory_ids
;;

let summary_to_json (s : summary) : Yojson.Safe.t =
  `Assoc
    [ "retrieved_count", `Int s.retrieved_count
    ; "retrieved_distinct_days", `Int s.retrieved_distinct_days
    ; ( "last_retrieved_at"
      , match s.last_retrieved_at with
        | None -> `Null
        | Some at -> `Float at )
    ; "retracted_count", `Int s.retracted_count
    ; "revised_from", `List (List.map (fun id -> `String id) s.revised_from)
    ]
;;
