type delivery_mode =
  | Full_entries
  | Reference_only

type pending_delivery = {
  from_seq : Workspace_memory_log.seq;
  to_seq : Workspace_memory_log.seq;
  digest_sha256 : string;
  entry_count : int;
  mode : delivery_mode;
}

type reader_state = {
  keeper : string;
  acknowledged_seq : Workspace_memory_log.seq;
  pending : pending_delivery option;
}

type turn_outcome =
  | Turn_succeeded
  | Turn_failed_transient
  | Context_overflow

type error =
  | No_pending_delivery
  | Digest_mismatch of { expected : string; actual : string }
  | Missing_committed_entries of
      { from_seq : Workspace_memory_log.seq
      ; to_seq : Workspace_memory_log.seq
      }
  | Single_entry_context_overflow of
      { seq : Workspace_memory_log.seq
      ; fact_id : string
      ; digest_sha256 : string
      }
  | Invalid_reader_state of string
  | Malformed_json of string
  | Io_error of string

open Result.Syntax

let error_to_string = function
  | No_pending_delivery ->
    "no_pending_delivery"
  | Digest_mismatch { expected; actual } ->
    Printf.sprintf "digest_mismatch(expected=%s, actual=%s)" expected actual
  | Missing_committed_entries { from_seq; to_seq } ->
    Printf.sprintf
      "missing_committed_entries(from_seq=%d, to_seq=%d)"
      from_seq
      to_seq
  | Single_entry_context_overflow { seq; fact_id; digest_sha256 } ->
    Printf.sprintf
      "single_entry_context_overflow(seq=%d, fact_id=%s, digest=%s)"
      seq
      fact_id
      digest_sha256
  | Invalid_reader_state detail ->
    Printf.sprintf "invalid_reader_state(%s)" detail
  | Malformed_json detail ->
    Printf.sprintf "malformed_json(%s)" detail
  | Io_error detail ->
    Printf.sprintf "io_error(%s)" detail

let init ~keeper ?(acknowledged_seq = 0) () =
  { keeper; acknowledged_seq; pending = None }

let sort_by_seq (entries : Workspace_memory_log.change_entry list) =
  List.sort
    (fun (a : Workspace_memory_log.change_entry)
         (b : Workspace_memory_log.change_entry) ->
       Int.compare a.seq b.seq)
    entries

let rec take n xs =
  if n <= 0 then
    []
  else
    match xs with
    | [] -> []
    | x :: rest -> x :: take (n - 1) rest

let compute_digest (entries : Workspace_memory_log.change_entry list) =
  let canonical =
    entries
    |> List.map (fun entry ->
      Workspace_memory_log.record_to_json_line
        (Workspace_memory_log.Change entry))
    |> String.concat "\n"
  in
  Agent_core_sha256.(digest_string canonical |> to_hex)

let slice_for_pending
    (p : pending_delivery)
    ~(committed : Workspace_memory_log.change_entry list) =
  let sorted = sort_by_seq committed in
  let slice =
    List.filter
      (fun (e : Workspace_memory_log.change_entry) ->
         e.seq >= p.from_seq && e.seq <= p.to_seq)
      sorted
  in
  if List.length slice <> p.entry_count then
    Error
      (Missing_committed_entries { from_seq = p.from_seq; to_seq = p.to_seq })
  else
    let actual_digest = compute_digest slice in
    if not (String.equal actual_digest p.digest_sha256) then
      Error
        (Digest_mismatch
           { expected = p.digest_sha256; actual = actual_digest })
    else
      Ok slice

let build_pending ?(mode = Full_entries) (slice : Workspace_memory_log.change_entry list) =
  match slice, List.rev slice with
  | first :: _, last :: _ ->
    Some
      { from_seq = first.seq
      ; to_seq = last.seq
      ; digest_sha256 = compute_digest slice
      ; entry_count = List.length slice
      ; mode
      }
  | _, _ -> None

let plan_unseen
    (state : reader_state)
    ~(committed : Workspace_memory_log.change_entry list)
    ?max_entries
    () =
  let unseen =
    committed
    |> sort_by_seq
    |> List.filter (fun (e : Workspace_memory_log.change_entry) ->
      e.seq > state.acknowledged_seq)
  in
  let selected =
    match max_entries with
    | None -> unseen
    | Some limit -> take (Int.max 0 limit) unseen
  in
  match build_pending selected with
  | None -> Ok ({ state with pending = None }, [])
  | Some pending -> Ok ({ state with pending = Some pending }, selected)

let plan_delivery
    (state : reader_state)
    ~(committed : Workspace_memory_log.change_entry list)
    ?max_entries
    () =
  match state.pending with
  | Some p ->
    let* slice = slice_for_pending p ~committed in
    Ok (state, slice)
  | None ->
    plan_unseen state ~committed ?max_entries ()

let recover_corrupted_pending
    (state : reader_state)
    ~(committed : Workspace_memory_log.change_entry list)
    ?max_entries
    () =
  match state.pending with
  | None -> Error No_pending_delivery
  | Some _ ->
    plan_unseen { state with pending = None } ~committed ?max_entries ()

let apply_turn_outcome
    (state : reader_state)
    ~(committed : Workspace_memory_log.change_entry list)
    (outcome : turn_outcome) =
  match state.pending with
  | None -> Error No_pending_delivery
  | Some p ->
    let* slice = slice_for_pending p ~committed in
    (match outcome with
     | Turn_succeeded ->
       Ok { state with acknowledged_seq = p.to_seq; pending = None }
     | Turn_failed_transient ->
       Ok state
     | Context_overflow ->
       if p.entry_count <= 1 then
         match p.mode, slice with
         | Full_entries, _ ->
           Ok { state with pending = Some { p with mode = Reference_only } }
         | Reference_only, first :: _ ->
           Error
             (Single_entry_context_overflow
                { seq = p.from_seq
                ; fact_id = first.fact_id
                ; digest_sha256 = p.digest_sha256
                })
         | Reference_only, [] ->
           Error
             (Missing_committed_entries
                { from_seq = p.from_seq; to_seq = p.to_seq })
       else
         let half = Int.max 1 (p.entry_count / 2) in
         let first_half = take half slice in
         (match build_pending ~mode:Full_entries first_half with
          | None ->
            Error
              (Missing_committed_entries
                 { from_seq = p.from_seq; to_seq = p.to_seq })
          | Some narrowed ->
            Ok { state with pending = Some narrowed }))

let delivery_mode_to_wire = function
  | Full_entries -> "full_entries"
  | Reference_only -> "reference_only"

let delivery_mode_of_wire = function
  | "full_entries" -> Ok Full_entries
  | "reference_only" -> Ok Reference_only
  | other ->
    Error
      (Invalid_reader_state
         (Printf.sprintf "unknown pending.mode: %s" other))

let pending_to_yojson (p : pending_delivery) =
  `Assoc
    [ "from_seq", `Int p.from_seq
    ; "to_seq", `Int p.to_seq
    ; "digest_sha256", `String p.digest_sha256
    ; "entry_count", `Int p.entry_count
    ; "mode", `String (delivery_mode_to_wire p.mode)
    ]

let reader_state_to_yojson (state : reader_state) =
  let pending_json =
    match state.pending with
    | None -> `Null
    | Some p -> pending_to_yojson p
  in
  `Assoc
    [ "keeper", `String state.keeper
    ; "acknowledged_seq", `Int state.acknowledged_seq
    ; "pending", pending_json
    ]

let require_object label = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Invalid_reader_state (label ^ " must be a JSON object"))

let require_field field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None ->
    Error (Invalid_reader_state ("missing required field: " ^ field))

let require_nonblank_string field fields =
  let* value = require_field field fields in
  match value with
  | `String s when not (String.equal (String.trim s) "") -> Ok s
  | _ ->
    Error (Invalid_reader_state (field ^ " must be a non-blank string"))

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false

let require_sha256 field fields =
  let* value = require_nonblank_string field fields in
  if String.length value = 64 && String.for_all is_lower_hex value then
    Ok value
  else
    Error
      (Invalid_reader_state
         (field ^ " must be a 64-character lowercase hex SHA-256 digest"))

let require_int ~min_value field fields =
  let* value = require_field field fields in
  match value with
  | `Int n when n >= min_value -> Ok n
  | _ ->
    Error
      (Invalid_reader_state
         (Printf.sprintf "%s must be an integer >= %d" field min_value))

let pending_of_yojson json =
  let* fields = require_object "pending" json in
  let* from_seq = require_int ~min_value:1 "from_seq" fields in
  let* to_seq = require_int ~min_value:from_seq "to_seq" fields in
  let* digest_sha256 = require_sha256 "digest_sha256" fields in
  let* entry_count = require_int ~min_value:1 "entry_count" fields in
  let* mode =
    match List.assoc_opt "mode" fields with
    | None -> Ok Full_entries
    | Some (`String raw) -> delivery_mode_of_wire raw
    | Some _ ->
      Error (Invalid_reader_state "pending.mode must be a string")
  in
  let* () =
    match mode with
    | Reference_only when entry_count <> 1 ->
      Error
        (Invalid_reader_state
           "pending.mode=reference_only requires entry_count = 1")
    | Reference_only | Full_entries -> Ok ()
  in
  Ok { from_seq; to_seq; digest_sha256; entry_count; mode }

let reader_state_of_yojson json =
  let* fields = require_object "reader_state" json in
  let* keeper = require_nonblank_string "keeper" fields in
  let* acknowledged_seq =
    require_int ~min_value:0 "acknowledged_seq" fields
  in
  let* pending_raw = require_field "pending" fields in
  let* pending =
    match pending_raw with
    | `Null -> Ok None
    | obj ->
      let* p = pending_of_yojson obj in
      if p.from_seq <= acknowledged_seq then
        Error
          (Invalid_reader_state
             "pending.from_seq must be greater than acknowledged_seq")
      else
        Ok (Some p)
  in
  Ok { keeper; acknowledged_seq; pending }

let reader_path ~base_path ~keeper =
  Filename.concat
    (Filename.concat
       (Workspace_memory_ledger.directory ~base_path)
       "readers")
    (keeper ^ ".json")

let io f =
  try f () with
  | Unix.Unix_error (error, fn, arg) ->
    Error
      (Io_error
         (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error)))
  | Sys_error detail -> Error (Io_error detail)
  | Eio.Io _ as exn -> Error (Io_error (Printexc.to_string exn))

let save_reader_state ~path (state : reader_state) =
  io (fun () ->
    Fs_compat.mkdir_p (Filename.dirname path);
    let content = Yojson.Safe.to_string (reader_state_to_yojson state) in
    match Fs_compat.save_file_atomic_strict_staged path content with
    | Ok () -> Ok ()
    | Error failure ->
      (match failure.exception_ with
       | Eio.Cancel.Cancelled _ as exn ->
         Printexc.raise_with_backtrace exn failure.backtrace
       | _ ->
         Error
           (Io_error (Fs_compat.atomic_replace_failure_to_string failure))))

let load_reader_state ~path =
  io (fun () ->
    match Fs_compat.load_file_opt path with
    | None -> Error (Io_error (path ^ ": reader state file does not exist"))
    | Some text ->
      let* json =
        try Ok (Yojson.Safe.from_string text) with
        | Yojson.Json_error detail -> Error (Malformed_json detail)
      in
      reader_state_of_yojson json)
