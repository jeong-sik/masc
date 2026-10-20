(* See .mli. *)

let sanitize_name name = Workspace_utils_backend_setup.sanitize_namespace_segment name
let ask_dir base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_ask"

let log_path ~base_path ~keeper_name =
  Filename.concat (ask_dir base_path) (sanitize_name keeper_name ^ ".jsonl")

let ensure_ask_dir ~base_path =
  let (_ : string) = Keeper_fs.ensure_dir (ask_dir base_path) in
  ()

type answer_failure =
  | Ask_not_found of { ask_id : string }
  | Already_answered of {
      answers : Keeper_ask.answer list;
      responder : Keeper_ask.responder;
      answered_at : float;
    }
  | Already_withdrawn of { reason : string; withdrawn_at : float }
  | Rejected of Keeper_ask.invalid_answer list
  | Store_failed of string
  | Answer_recorded_unconfirmed of { detail : string }

type read_error =
  | Log_read_failed of { path : string; detail : string }
  | Log_decode_failed of { path : string; line : int; detail : string }

type row = string * (Keeper_ask.ask * Keeper_ask.resolution)
type rows_snapshot = Missing_log | Stored_rows of row list

let read_error_to_string = function
  | Log_read_failed { path; detail } -> Printf.sprintf "%s ask log read failed: %s" path detail
  | Log_decode_failed { path; line; detail } ->
      Printf.sprintf "%s:%d ask log decode failed: %s" path line detail

let read_error_path = function
  | Log_read_failed { path; _ } | Log_decode_failed { path; _ } -> path

type withdraw_failure =
  | Withdraw_ask_not_found of { ask_id : string }
  | Withdraw_already_answered of { answered_at : float }
  | Withdraw_already_withdrawn of { withdrawn_at : float }
  | Withdraw_store_failed of string

let answer_failure_to_string = function
  | Ask_not_found { ask_id } -> "no such ask: " ^ ask_id
  | Already_answered { answered_at; _ } ->
      Printf.sprintf "already answered at %.0f" answered_at
  | Already_withdrawn { reason; _ } -> "already withdrawn: " ^ reason
  | Rejected errors ->
      String.concat "; " (List.map Keeper_ask.invalid_answer_to_string errors)
  | Store_failed detail -> "store failed: " ^ detail
  | Answer_recorded_unconfirmed { detail } ->
      "answer append committed but canonical answer could not be confirmed: " ^ detail

let withdraw_failure_to_string = function
  | Withdraw_ask_not_found { ask_id } -> "no such ask: " ^ ask_id
  | Withdraw_already_answered { answered_at } ->
      Printf.sprintf "already answered at %.0f" answered_at
  | Withdraw_already_withdrawn { withdrawn_at } ->
      Printf.sprintf "already withdrawn at %.0f" withdrawn_at
  | Withdraw_store_failed detail -> "store failed: " ^ detail

(* Every read validates the owned descriptor and its before/after snapshot.
   Keep decoding work only for those exact validated bytes; a same-size write
   restoring mtime cannot turn old events into mutation authority. *)
let decoded_logs :
    (string, Fs_compat.owned_regular_file_snapshot * string * Keeper_ask.event list) Hashtbl.t =
  Hashtbl.create 16
let decoded_logs_mutex = Stdlib.Mutex.create ()

let forget_log path =
  Stdlib.Mutex.protect decoded_logs_mutex (fun () -> Hashtbl.remove decoded_logs path)

let append_event ~base_path ~keeper_name event =
  let path = log_path ~base_path ~keeper_name in
  let appended =
    try
      ensure_ask_dir ~base_path;
      let suffix = Yojson.Safe.to_string (Keeper_ask.event_to_json event) ^ "\n" in
      (match Fs_compat.append_private_jsonl_durable_locked_result path suffix with
       | Fs_compat.Private_file_succeeded () -> Ok ()
       | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
           Log.Keeper.warn "keeper_ask_store: append committed; descriptor cleanup failed: %s"
             (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
           Ok ()
       | Fs_compat.Private_file_failed error ->
           Error (Fs_compat.private_jsonl_append_error_to_string error)
       | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
           Error (Fs_compat.private_jsonl_append_error_to_string error ^ "; " ^
             Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
    with
    | Eio.Cancel.Cancelled _ as e ->
        forget_log path;
        raise e
    | exn ->
        let detail = Printexc.to_string exn in
        Log.Keeper.warn "keeper_ask_store: append failed for %s: %s" (sanitize_name keeper_name)
          detail;
        Error detail
  in
  (* Landed or not, the log may no longer be the version that was decoded. *)
  forget_log path;
  appended

let decode_line line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error detail -> Error detail
  | json -> Keeper_ask.event_of_json json

let decode_log ~path content =
      (* As [fold_appended_lines], read only newline-complete nonblank rows.
         Keep its final complete malformed-line policy as well. *)
      let complete_lines = match List.rev (String.split_on_char '\n' content) with
        | [] -> []
        | _tail :: complete -> List.rev complete in
      let lines = List.filter_map (fun line ->
          let trimmed = String.trim line in if trimmed = "" then None else Some trimmed) complete_lines in
      let parsed = List.mapi (fun index line -> index + 1, decode_line line) lines in
      let line_count = List.length lines in
      (* A final line that does not decode is the shape an append cut short by
         a crash leaves. Anywhere else it means the history itself is damaged,
         and a reader that skipped it would report a shortened past as
         complete. *)
      let fatal =
        List.filter_map
          (fun (line_no, result) ->
            match result with
            | Ok _ -> None
            | Error detail -> if line_no = line_count then None else Some (line_no, detail))
          parsed
      in
      match fatal with
      | (line_no, detail) :: _ ->
          Error (Log_decode_failed { path; line = line_no; detail })
      | [] ->
          Ok
            (List.filter_map
               (fun (_, result) -> match result with Ok event -> Some event | Error _ -> None)
               parsed)

let load_events_at_path_result ~base_path ~path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
      ~ownership_root:(Common.masc_dir_from_base_path ~base_path) path with
  | Error error -> Error (Log_read_failed
      { path; detail = Fs_compat.owned_regular_file_read_error_to_string error })
  | Ok None -> forget_log path; Ok None
  | Ok (Some { content; snapshot }) ->
      let held = Stdlib.Mutex.protect decoded_logs_mutex
          (fun () -> Hashtbl.find_opt decoded_logs path) in
      (match held with
       | Some (previous, bytes, events)
         when Fs_compat.equal_owned_regular_file_snapshot previous snapshot
           && String.equal bytes content -> Ok (Some events)
       | Some _ | None ->
           match decode_log ~path content with
           | Error error -> forget_log path; Error error
           | Ok events ->
               Stdlib.Mutex.protect decoded_logs_mutex
                 (fun () -> Hashtbl.replace decoded_logs path (snapshot, content, events));
               Ok (Some events))

let validate_owner ~base_path ~path ~keeper_name events =
  List.find_map (fun (index, event) ->
    match event with
    | Keeper_ask.Asked ask when not (String.equal ask.Keeper_ask.keeper_name keeper_name)
        || not (String.equal (log_path ~base_path ~keeper_name:ask.keeper_name) path) ->
        Some (Log_decode_failed { path; line = index + 1;
          detail = "Asked record belongs to a different canonical Keeper log" })
    | Keeper_ask.Asked _ | Keeper_ask.Answered _ | Keeper_ask.Withdrawn _ -> None)
    (List.mapi (fun index event -> index, event) events)
  |> function None -> Ok events | Some error -> Error error

let load_events_result ~base_path ~keeper_name =
  let path = log_path ~base_path ~keeper_name in
  match load_events_at_path_result ~base_path ~path with
  | Error error -> Error error
  | Ok None -> Ok None
  | Ok (Some events) -> Result.map Option.some
      (validate_owner ~base_path ~path ~keeper_name events)

let rows_result ~base_path ~keeper_name =
  Result.map (function
    | None -> Missing_log
    | Some events -> Stored_rows (Keeper_ask.fold_events events))
    (load_events_result ~base_path ~keeper_name)

type discovered_log =
  | Canonical_rows of { keeper_name : string; rows : row list }
  | Unreadable_log of read_error

let compare_discovered_log a b =
  match a, b with
  | Canonical_rows { keeper_name = ka; _ }, Canonical_rows { keeper_name = kb; _ } ->
      String.compare ka kb
  | Unreadable_log ea, Unreadable_log eb ->
      String.compare (read_error_path ea) (read_error_path eb)
  | Canonical_rows _, Unreadable_log _ -> -1
  | Unreadable_log _, Canonical_rows _ -> 1

let discover_rows_result ~base_path =
  let path = ask_dir base_path in
  match Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.getuid ())
      ~ownership_root:(Common.masc_dir_from_base_path ~base_path) path with
  | Error error -> Error (Log_read_failed
      { path; detail = Fs_compat.owned_regular_file_read_error_to_string error })
  | Ok None -> Ok []
  | Ok (Some names) ->
      let names = List.sort String.compare names in
      let discovered =
        List.filter_map (fun name ->
          if not (Filename.check_suffix name ".jsonl") then None else
          let path = Filename.concat path name in
          match load_events_at_path_result ~base_path ~path with
          | Error error -> Some (Unreadable_log error)
          (* A file that was unlinked between [read_owned_directory_if_present]
             and [load_events_at_path_result] makes this single scan incomplete
             (503 for fleet list callers), and resolves on the next retry once
             the directory listing no longer contains the unlinked entry. *)
          | Ok None -> Some (Unreadable_log (Log_read_failed
              { path; detail = "discovered ask log disappeared before its owned read" }))
          | Ok (Some events) ->
              match List.find_map (function Keeper_ask.Asked ask -> Some ask.Keeper_ask.keeper_name
                  | Keeper_ask.Answered _ | Keeper_ask.Withdrawn _ -> None) events with
              | None ->
                  if events = [] then None else Some (Unreadable_log (Log_decode_failed
                      { path; line = 1; detail = "ask events have no canonical Asked owner" }))
              | Some keeper_name ->
                  match validate_owner ~base_path ~path ~keeper_name events with
                  | Error error -> Some (Unreadable_log error)
                  | Ok events -> Some (Canonical_rows { keeper_name; rows = Keeper_ask.fold_events events })) names
      in
      Ok (List.sort compare_discovered_log discovered)

let load_events ~base_path ~keeper_name =
  match load_events_result ~base_path ~keeper_name with
  | Ok (Some events) -> events
  | Ok None -> []
  | Error msg ->
      Log.Keeper.warn "keeper_ask_store: %s" (read_error_to_string msg);
      []

let rows ~base_path ~keeper_name =
  Keeper_ask.fold_events (load_events ~base_path ~keeper_name)

let open_asks ~base_path ~keeper_name =
  Keeper_ask.open_asks (load_events ~base_path ~keeper_name)

let open_ask_count ~base_path ~keeper_name =
  List.length (open_asks ~base_path ~keeper_name)

let settled ~base_path ~keeper_name ~ask_id =
  List.find_map
    (fun (id, (_, resolution)) -> if String.equal id ask_id then Some resolution else None)
    (rows ~base_path ~keeper_name)

let record_ask ~base_path (a : Keeper_ask.ask) =
  append_event ~base_path ~keeper_name:a.keeper_name (Keeper_ask.Asked a)

let find_row rows_list ask_id =
  List.find_map
    (fun (id, row) -> if String.equal id ask_id then Some row else None)
    rows_list

let answer_with_interleaving ~before_append ~after_append
    ~base_path ~keeper_name ~ask_id ~submissions ~responder ~now =
  let ( let* ) = Result.bind in
  let* snapshot = rows_result ~base_path ~keeper_name
      |> Result.map_error (fun error -> Store_failed (read_error_to_string error)) in
  let rows = match snapshot with Missing_log -> [] | Stored_rows rows -> rows in
  match find_row rows ask_id with
  | None -> Error (Ask_not_found { ask_id })
  | Some (_, Keeper_ask.Answered_by { answers; responder; answered_at }) ->
      Error (Already_answered { answers; responder; answered_at })
  | Some (_, Keeper_ask.Withdrawn_because { reason; withdrawn_at }) ->
      Error (Already_withdrawn { reason; withdrawn_at })
  | Some (recorded_ask, Keeper_ask.Open) -> (
      match Keeper_ask.parse_answers ~ask:recorded_ask ~submissions with
      | Error errors -> Error (Rejected errors)
      | Ok answers -> (
          let event =
            Keeper_ask.Answered { ask_id; answers; responder; answered_at = now }
          in
          before_append ();
          match append_event ~base_path ~keeper_name event with
          | Ok () ->
              after_append ();
              (match rows_result ~base_path ~keeper_name with
               | Error error -> Error (Answer_recorded_unconfirmed
                   { detail = read_error_to_string error })
               | Ok snapshot ->
                   let rows = match snapshot with Missing_log -> [] | Stored_rows rows -> rows in
                   (match find_row rows ask_id with
                    | Some (_, Keeper_ask.Answered_by canonical)
                      when canonical.answers = answers && canonical.responder = responder
                        && canonical.answered_at = now -> Ok canonical.answers
                    | Some (_, Keeper_ask.Answered_by { answers; responder; answered_at }) ->
                        Error (Already_answered { answers; responder; answered_at })
                    | None | Some (_, (Keeper_ask.Open | Keeper_ask.Withdrawn_because _)) ->
                        Error (Answer_recorded_unconfirmed
                          { detail = "committed append has no canonical answered row" })))
          | Error detail -> Error (Store_failed detail)))

let answer = answer_with_interleaving ~before_append:(fun () -> ()) ~after_append:(fun () -> ())

let withdraw ~base_path ~keeper_name ~ask_id ~reason ~now =
  let ( let* ) = Result.bind in
  let* snapshot = rows_result ~base_path ~keeper_name
      |> Result.map_error (fun error -> Withdraw_store_failed (read_error_to_string error)) in
  let rows = match snapshot with Missing_log -> [] | Stored_rows rows -> rows in
  match find_row rows ask_id with
  | None -> Error (Withdraw_ask_not_found { ask_id })
  | Some (_, Keeper_ask.Answered_by { answered_at; _ }) ->
      Error (Withdraw_already_answered { answered_at })
  | Some (_, Keeper_ask.Withdrawn_because { withdrawn_at; _ }) ->
      Error (Withdraw_already_withdrawn { withdrawn_at })
  | Some (_, Keeper_ask.Open) -> (
      let event = Keeper_ask.Withdrawn { ask_id; reason; withdrawn_at = now } in
      match append_event ~base_path ~keeper_name event with
      | Ok () -> Ok ()
      | Error detail -> Error (Withdraw_store_failed detail))

module For_testing = struct
  let answer_with_interleaving = answer_with_interleaving
end
