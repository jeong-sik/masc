(* Memory history events (RFC-0418). See the interface for the contract. *)

module W = Keeper_memory_os_types

let ( let* ) = Result.bind
let ( let+ ) r f = Result.map f r
let suffix = ".memory-events.jsonl"

let path_for_keepers_dir ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ suffix)
;;

type event_kind =
  | Retrieved of { query : string }
  | Retracted
  | Revised of { superseded_by : string }

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
let field_superseded_by = "superseded_by"
let kind_retrieved = "retrieved"
let kind_retracted = "retracted"
let kind_revised = "revised"
let common_fields = [ field_recorded_at; field_memory_id; field_trace_id; field_kind ]

let kind_token = function
  | Retrieved _ -> kind_retrieved
  | Retracted -> kind_retracted
  | Revised _ -> kind_revised
;;

(* Only events with additional data carry a payload field. *)
let payload = function
  | Retrieved { query } -> [ field_query, `String query ]
  | Retracted -> []
  | Revised { superseded_by } -> [ field_superseded_by, `String superseded_by ]
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
    | Retracted -> Ok ()
    | Revised { superseded_by } ->
      if W.is_memory_id superseded_by
      then Ok ()
      else
        W.wire_fail
          [ W.Wire_field field_superseded_by ]
          (W.Not_a_memory_id superseded_by)
  in
  e
;;

let kind_of_token token =
  match token with
  | "retrieved" ->
    Ok ([ field_query ], fun fields ->
      let+ query = W.wire_string_field field_query fields in Retrieved { query })
  | "retracted" -> Ok ([], fun _ -> Ok Retracted)
  | "revised" ->
    Ok ([ field_superseded_by ], fun fields ->
      let+ superseded_by = W.wire_string_field field_superseded_by fields in
      Revised { superseded_by })
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
   A producer on a path that must not fail (a search returning its results, a
   librarian pass that has committed) reports what comes back in its log and
   goes on. *)
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

let read ~keepers_dir ~keeper_id :
    ((int * (event, read_error) result) list, file_read_error) result =
  let path = path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Fs_compat.load_file_opt path with
  | exception Sys_error message -> Error { path; message }
  | None -> Ok []
  | Some contents ->
    Ok
      (String.split_on_char '\n' contents
       |> List.filter (fun line -> non_blank line)
       |> List.mapi (fun index line ->
         match Yojson.Safe.from_string line with
         | json ->
           ( index
           , (match event_of_json json with
              | Ok event -> Ok event
              | Error error -> Error (Malformed error)) )
         | exception Yojson.Json_error message -> index, Error (Not_json message)))
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

let summary_for ~memory_id (events : event list) : summary =
  let about_this, about_others =
    List.partition (fun (e : event) -> String.equal e.memory_id memory_id) events
  in
  let retrieved_at =
    List.filter_map
      (fun (e : event) ->
         match e.kind with
         | Retrieved _ -> Some e.recorded_at
         | Retracted | Revised _ -> None)
      about_this
  in
  let retracted_count =
    List.length
      (List.filter
         (fun (e : event) ->
            match e.kind with
            | Retracted -> true
            | Retrieved _ | Revised _ -> false)
         about_this)
  in
  let revised_from =
    List.filter_map
      (fun (e : event) ->
         match e.kind with
         | Revised { superseded_by } when String.equal superseded_by memory_id ->
           Some e.memory_id
         | Revised _ | Retrieved _ | Retracted -> None)
      about_others
    |> List.sort_uniq String.compare
  in
  { retrieved_count = List.length retrieved_at
  ; retrieved_distinct_days =
      List.map utc_day retrieved_at |> List.sort_uniq Int.compare |> List.length
  ; last_retrieved_at =
      List.fold_left
        (fun latest at ->
           match latest with
           | None -> Some at
           | Some seen -> Some (Float.max seen at))
        None
        retrieved_at
  ; retracted_count
  ; revised_from
  }
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
