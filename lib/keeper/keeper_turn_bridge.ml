(* Turns carried across a runtime switch. See [keeper_turn_bridge.mli] for
   the contract. *)

open Result.Syntax

let bridged_turn_ref_metadata_key = "masc.bridged_turn_ref"
let client_turns_filename = "client-turns.jsonl"

type session_key =
  { client_kind : Keeper_semantic_execution.official_client_kind
  ; runtime_id : string
  ; session_id : string
  }

type client_turn =
  { turn_ref : Ids.Turn_ref.t
  ; session : session_key option
  }

type turn_log_refusal =
  | Log_unread of Private_jsonl_scan.error
  | Line_undecodable of
      { offset : int
      ; reason : Keeper_turn_log_store.undecodable
      }
  | Line_out_of_order of
      { offset : int
      ; error : Keeper_turn_log.order_error
      }

type bridge_load_error =
  | Turn_log_refused of turn_log_refusal
  | Ledger_unreadable of string
  | Ledger_line_unreadable of
      { line : int
      ; detail : string
      }
  | Cursor_turn_not_in_log of Ids.Turn_ref.t
  | Fragment_store_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; detail : string
      }
  | Fragment_line_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; line : int
      ; error : Keeper_turn_fragments.read_error
      }

let fragment_file_label = function
  | Keeper_turn_fragments.Main -> "history.jsonl"
  | Keeper_turn_fragments.Internal -> "history.internal.jsonl"
;;

let turn_log_refusal_to_string = function
  | Log_unread error -> "turn log unread: " ^ Private_jsonl_scan.error_to_string error
  | Line_undecodable { offset; reason = Not_json } ->
    Printf.sprintf "turn log line at %d is not JSON" offset
  | Line_undecodable { offset; reason = Malformed error } ->
    Printf.sprintf
      "turn log line at %d does not decode: %s"
      offset
      (Keeper_memory_os_types.wire_error_to_string error)
  | Line_out_of_order { offset; error } ->
    Printf.sprintf
      "turn log line at %d is out of order: %s"
      offset
      (Keeper_turn_log.order_error_to_string error)
;;

let bridge_load_error_to_string = function
  | Turn_log_refused refusal -> turn_log_refusal_to_string refusal
  | Ledger_unreadable detail -> "official-client turn ledger unreadable: " ^ detail
  | Ledger_line_unreadable { line; detail } ->
    Printf.sprintf "official-client turn ledger line %d unreadable: %s" line detail
  | Cursor_turn_not_in_log turn_ref ->
    Printf.sprintf
      "the turn log has no turn %s, the resumed session's last turn"
      (Ids.Turn_ref.to_string turn_ref)
  | Fragment_store_unreadable { trace_id; file; detail } ->
    Printf.sprintf
      "fragment store %s for trace %s unreadable: %s"
      (fragment_file_label file)
      trace_id
      detail
  | Fragment_line_unreadable { trace_id; file; line; error } ->
    Printf.sprintf
      "fragment line %d in %s for trace %s unreadable: %s"
      line
      (fragment_file_label file)
      trace_id
      (Keeper_turn_fragments.read_error_to_string error)
;;

let bridged_turn_ref_of_message (msg : Agent_core.Types.message) =
  List.find_map
    (fun (key, value) ->
       if String.equal key bridged_turn_ref_metadata_key
       then
         match value with
         | `String raw -> Ids.Turn_ref.of_string raw
         | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ -> None
       else None)
    msg.Agent_core.Types.metadata
;;

let stamp_bridged_turn_ref turn_ref (msg : Agent_core.Types.message) =
  let cleaned =
    List.filter
      (fun (key, _) -> not (String.equal key bridged_turn_ref_metadata_key))
      msg.Agent_core.Types.metadata
  in
  { msg with
    metadata =
      (bridged_turn_ref_metadata_key, `String (Ids.Turn_ref.to_string turn_ref))
      :: cleaned
  }
;;

(* ---- The ledger of turns an official client answered ---- *)

let client_turns_path ~base_path ~keeper_name =
  Result.map
    (fun directory -> Filename.concat directory client_turns_filename)
    (Keeper_official_client_paths.state_dir ~base_path ~keeper_name)
;;

let session_key_equal (key : session_key) ~client_kind ~runtime_id ~session_id =
  key.client_kind = client_kind
  && String.equal key.runtime_id runtime_id
  && String.equal key.session_id session_id
;;

let validate_session = function
  | None -> Ok ()
  | Some { client_kind = (_ : Keeper_semantic_execution.official_client_kind); runtime_id; session_id }
    ->
    if String.equal (String.trim runtime_id) ""
    then Error "runtime_id must not be blank"
    else if String.equal (String.trim session_id) ""
    then Error "session_id must not be blank"
    else Ok ()
;;

let client_turn_to_json { turn_ref; session } =
  let session_json =
    match session with
    | None -> `Null
    | Some { client_kind; runtime_id; session_id } ->
      `Assoc
        [ ( "client_kind"
          , `String (Keeper_semantic_execution.official_client_kind_to_string client_kind) )
        ; "runtime_id", `String runtime_id
        ; "session_id", `String session_id
        ]
  in
  `Assoc [ "session", session_json; "turn_ref", `String (Ids.Turn_ref.to_string turn_ref) ]
;;

let sorted_fields fields =
  List.sort (fun (left, _) (right, _) -> String.compare left right) fields
;;

let session_of_json : Yojson.Safe.t -> (session_key option, string) result = function
  | `Null -> Ok None
  | `Assoc fields ->
    (match sorted_fields fields with
     | [ "client_kind", `String kind_raw
       ; "runtime_id", `String runtime_id
       ; "session_id", `String session_id
       ] ->
       (match Keeper_semantic_execution.official_client_kind_of_string kind_raw with
        | None -> Error ("unknown client_kind: " ^ kind_raw)
        | Some client_kind ->
          let session = Some { client_kind; runtime_id; session_id } in
          let* () = validate_session session in
          Ok session)
     | _ -> Error "session fields are not exact")
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "session is neither an object nor null"
;;

let client_turn_of_row row =
  match Yojson.Safe.from_string row with
  | exception Yojson.Json_error message -> Error ("not JSON: " ^ message)
  | `Assoc fields ->
    (match sorted_fields fields with
     | [ "session", session_json; "turn_ref", `String turn_ref_raw ] ->
       let* session = session_of_json session_json in
       (match Ids.Turn_ref.of_string turn_ref_raw with
        | Some turn_ref -> Ok { turn_ref; session }
        | None -> Error ("invalid turn_ref: " ^ turn_ref_raw))
     | _ -> Error "fields are not exact")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "not a JSON object"
;;

(* [rows] ends with the line break of its last row: what follows that break
   is no row. A torn tail after it is not handed over by the read, and the
   next append cuts it. *)
let client_turns_of_rows rows =
  let complete =
    match List.rev (String.split_on_char '\n' rows) with
    | [] -> []
    | (_ : string) :: reversed -> List.rev reversed
  in
  let rec decode entries_rev line = function
    | [] -> Ok (List.rev entries_rev)
    | row :: rest ->
      (match client_turn_of_row row with
       | Ok entry -> decode (entry :: entries_rev) (line + 1) rest
       | Error detail -> Error (Ledger_line_unreadable { line; detail }))
  in
  decode [] 1 complete
;;

let read_client_turns ~base_path ~keeper_name =
  let* path =
    client_turns_path ~base_path ~keeper_name
    |> Result.map_error (fun detail -> Ledger_unreadable detail)
  in
  let of_rows = function
    | Fs_compat.Private_jsonl_rows.Rows_missing -> Ok []
    | Fs_compat.Private_jsonl_rows.Rows_present
        { rows; rows_end = (_ : int); end_offset = (_ : int) } -> client_turns_of_rows rows
  in
  let settled cleanup_failure =
    Log.Keeper.warn
      ~keeper_name
      "official-client turn ledger read; descriptor settlement failed path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  in
  let unreadable error =
    Error (Ledger_unreadable (Fs_compat.Private_jsonl_rows.error_to_string error))
  in
  match Fs_compat.read_private_jsonl_rows_locked_result path with
  | Fs_compat.Private_file_succeeded rows -> of_rows rows
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
    settled cleanup_failure;
    of_rows value
  | Fs_compat.Private_file_failed error -> unreadable error
  | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    settled cleanup_failure;
    unreadable error
;;

let record_client_turn ~base_path ~keeper_name client_turn =
  let* () = validate_session client_turn.session in
  let* path = client_turns_path ~base_path ~keeper_name in
  let* () =
    try
      let (_ : string) = Keeper_fs.ensure_dir (Filename.dirname path) in
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  in
  let line = Yojson.Safe.to_string (client_turn_to_json client_turn) ^ "\n" in
  let failed message =
    Error (Printf.sprintf "official-client turn ledger append failed path=%s: %s" path message)
  in
  match Fs_compat.append_private_jsonl_durable_locked_result path line with
  | Fs_compat.Private_file_succeeded () -> Ok ()
  | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
    Log.Keeper.warn
      ~keeper_name
      "official-client turn ledger append committed; descriptor settlement failed path=%s: %s"
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
  | exception Sys_error message -> failed message
  | exception Unix.Unix_error (code, fn, arg) ->
    failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
;;

module Turn_ref_set = Set.Make (String)

let answered_by_client entries =
  List.fold_left
    (fun answered { turn_ref; session = (_ : session_key option) } ->
       Turn_ref_set.add (Ids.Turn_ref.to_string turn_ref) answered)
    Turn_ref_set.empty
    entries
;;

let client_answered answered turn_ref =
  Turn_ref_set.mem (Ids.Turn_ref.to_string turn_ref) answered
;;

let last_settled_turn ~client_kind ~runtime_id ~session_id entries =
  List.fold_left
    (fun last { turn_ref; session } ->
       match session with
       | Some key when session_key_equal key ~client_kind ~runtime_id ~session_id ->
         Some turn_ref
       | Some (_ : session_key) | None -> last)
    None
    entries
;;

(* ---- The turn log, read as the turns of one trace ---- *)

type turn_event =
  | Turn_opened of Ids.Turn_ref.t
  | Turn_closed of
      { turn_ref : Ids.Turn_ref.t
      ; outcome : Keeper_turn_log.outcome
      ; owns_messages : bool
      }
  | History_reset of { trace_id : string }

type turn_scan =
  { position : Keeper_turn_log.position
  ; open_turn : Ids.Turn_ref.t option
  ; events_rev : turn_event list
  }

let turn_scan_start =
  { position = Keeper_turn_log.Nothing_written; open_turn = None; events_rev = [] }
;;

(* [Keeper_turn_log.step] has accepted [line] before this runs, so a [Closed]
   always closes the turn [open_turn] names. *)
let turn_scan_step scan (line : Keeper_turn_log.line) =
  match line with
  | Log_started _ -> scan
  | Opened { turn_ref; _ } ->
    { scan with open_turn = Some turn_ref; events_rev = Turn_opened turn_ref :: scan.events_rev }
  | Closed { outcome; own; _ } ->
    let owns_messages =
      match own with
      | [] -> false
      | (_ : Keeper_turn_log.slice) :: _ -> true
    in
    (match scan.open_turn with
     | None -> scan
     | Some turn_ref ->
       { scan with
         open_turn = None
       ; events_rev = Turn_closed { turn_ref; outcome; owns_messages } :: scan.events_rev
       })
  | Reset { cause; after; _ } ->
    if Keeper_turn_log.counts_as_restart cause
    then { scan with events_rev = History_reset { trace_id = after.trace } :: scan.events_rev }
    else scan
;;

let turn_log_path ~base_path ~keeper_name =
  Keeper_turn_log_store.path_for_keepers_dir
    ~keepers_dir:(Common.keepers_runtime_dir_of_base ~base_path)
    ~keeper_id:keeper_name
;;

(* Every line from the first, in order. A line that does not decode or
   breaks the order stops the read and refuses it. *)
let read_turn_events ~base_path ~keeper_name =
  match
    Keeper_turn_log_store.fold_from
      (turn_log_path ~base_path ~keeper_name)
      ~from:0
      ~init:turn_scan_start
      ~f:(fun scan (scanned : Keeper_turn_log_store.scanned) ->
        match scanned.line with
        | Error reason ->
          Private_jsonl_scan.Stop (Line_undecodable { offset = scanned.at; reason })
        | Ok line ->
          (match Keeper_turn_log.step scan.position ~offset:scanned.at line with
           | Error error ->
             Private_jsonl_scan.Stop (Line_out_of_order { offset = scanned.at; error })
           | Ok position ->
             Private_jsonl_scan.Continue (turn_scan_step { scan with position } line)))
  with
  | Ok (Private_jsonl_scan.Reached_end scan) -> Ok (List.rev scan.events_rev)
  | Ok (Private_jsonl_scan.Stopped refusal) -> Error (Turn_log_refused refusal)
  | Error (Private_jsonl_scan.Scan_failed error) -> Error (Turn_log_refused (Log_unread error))
  | Error (Private_jsonl_scan.Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
    (* Offset 0 starts a line in any file, so the file changed under the
       read. *)
    Error (Turn_log_refused (Log_unread Private_jsonl_scan.Moved))
;;

let of_trace ~trace_id turn_ref = String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id

(* An Agent Core turn whose save wrote the head: it completed, which an Agent
   Core turn does only after its closing save was [Saved], or its [own] names
   messages that save closed. *)
let saved_the_head ~(outcome : Keeper_turn_log.outcome) ~owns_messages =
  owns_messages
  ||
  match outcome with
  | Completed -> true
  | Errored | Cancelled | Save_failed | Stale_save | Close_missing | Process_exited -> false
;;

(* The turns of [trace_id] an official client answered since the last save
   of the head or the last counted reset, in the order they closed. *)
let pending_client_turns ~trace_id ~answered events =
  List.fold_left
    (fun pending_rev event ->
       match event with
       | Turn_opened (_ : Ids.Turn_ref.t) -> pending_rev
       | History_reset { trace_id = restarted } ->
         if String.equal restarted trace_id then [] else pending_rev
       | Turn_closed { turn_ref; outcome; owns_messages } ->
         if not (of_trace ~trace_id turn_ref)
         then pending_rev
         else if client_answered answered turn_ref
         then turn_ref :: pending_rev
         else if saved_the_head ~outcome ~owns_messages
         then []
         else pending_rev)
    []
    events
  |> List.rev
;;

(* A turn a resumed session is told about. An Agent Core turn that ended
   before its closing save left at most its input, which the next turn
   repeats. *)
let carried_to_a_resume ~(outcome : Keeper_turn_log.outcome) ~owns_messages =
  owns_messages
  ||
  match outcome with
  | Completed | Stale_save -> true
  | Errored | Cancelled | Save_failed | Close_missing | Process_exited -> false
;;

(* The turns of [trace_id] closed after the last [Opened] of [cursor]. *)
let turns_after_cursor ~trace_id ~answered ~cursor events =
  let found, carried_rev =
    List.fold_left
      (fun (found, carried_rev) event ->
         match event with
         | Turn_opened turn_ref ->
           if Ids.Turn_ref.equal turn_ref cursor then true, [] else found, carried_rev
         | History_reset { trace_id = restarted } ->
           if String.equal restarted trace_id then found, [] else found, carried_rev
         | Turn_closed { turn_ref; outcome; owns_messages } ->
           if found
              && of_trace ~trace_id turn_ref
              && (not (Ids.Turn_ref.equal turn_ref cursor))
              && (client_answered answered turn_ref
                  || carried_to_a_resume ~outcome ~owns_messages)
           then found, turn_ref :: carried_rev
           else found, carried_rev)
      (false, [])
      events
  in
  if found then Ok (List.rev carried_rev) else Error (Cursor_turn_not_in_log cursor)
;;

let read_trace_fragments ~trace_id ~session_dir =
  let read_file file =
    let* lines =
      Keeper_turn_fragments.read ~session_dir file
      |> Result.map_error (fun detail ->
        Fragment_store_unreadable { trace_id; file; detail })
    in
    match Keeper_turn_fragments.first_refused lines with
    | Some (line, error) ->
      Error (Fragment_line_unreadable { trace_id; file; line; error })
    | None -> Ok lines
  in
  let* main = read_file Keeper_turn_fragments.Main in
  let* internal = read_file Keeper_turn_fragments.Internal in
  Ok (main, internal)
;;

let outcome_label = function
  | Keeper_librarian.Succeeded -> "ok"
  | Keeper_librarian.Failed -> "failed"
  | Keeper_librarian.Unknown -> "unknown"
;;

let format_tool_observations observations =
  observations
  |> List.map (fun (obs : Keeper_librarian.tool_observation) ->
    Printf.sprintf "%s (%s)" obs.tool_name (outcome_label obs.outcome))
  |> String.concat ", "
;;

let messages_for_turn turn_ref fragments =
  let msgs_rev, obs_rev =
    List.fold_left
      (fun (msgs, obs) fragment ->
         match fragment with
         | Keeper_turn_fragments.Message observed ->
           stamp_bridged_turn_ref turn_ref observed.message :: msgs, obs
         | Keeper_turn_fragments.Tool_observation { observation; _ } ->
           msgs, observation :: obs)
      ([], [])
      fragments
  in
  let msgs = List.rev msgs_rev in
  let obs = List.rev obs_rev in
  match obs with
  | [] -> msgs
  | _ :: _ ->
    let note =
      Printf.sprintf
        "[Official-client turn %s tool observations: %s]"
        (Ids.Turn_ref.to_string turn_ref)
        (format_tool_observations obs)
    in
    let rec attach_to_last_assistant rev_acc attached = function
      | [] ->
        if attached
        then List.rev rev_acc
        else
          let base =
            match msgs with
            | [] ->
              [ stamp_bridged_turn_ref
                  turn_ref
                  (Agent_core.Types.make_message
                     ~role:Agent_core.Types.User
                     ~origin:Agent_core.Types.Conversation
                     [ Agent_core.Types.Text "[Official-client turn]" ])
              ]
            | _ :: _ -> List.rev rev_acc
          in
          base
          @ [ stamp_bridged_turn_ref
                turn_ref
                (Agent_core.Types.make_message
                   ~role:Agent_core.Types.Assistant
                   ~origin:Agent_core.Types.Conversation
                   [ Agent_core.Types.Text note ])
            ]
      | (msg : Agent_core.Types.message) :: rest ->
        let is_assistant =
          match msg.role with
          | Agent_core.Types.Assistant -> true
          | Agent_core.Types.System | Agent_core.Types.User | Agent_core.Types.Tool -> false
        in
        if (not attached) && is_assistant
        then
          let updated =
            { msg with content = msg.content @ [ Agent_core.Types.Text ("\n\n" ^ note) ] }
          in
          attach_to_last_assistant (updated :: rev_acc) true rest
        else attach_to_last_assistant (msg :: rev_acc) attached rest
    in
    attach_to_last_assistant [] false (List.rev msgs)
;;

let uncheckpointed_official_turns
      ~base_path
      ~keeper_name
      ~trace_id
      ~session_dir
      ~existing_messages
  =
  let* events = read_turn_events ~base_path ~keeper_name in
  let* entries = read_client_turns ~base_path ~keeper_name in
  let pending =
    pending_client_turns ~trace_id ~answered:(answered_by_client entries) events
  in
  let already_bridged =
    List.filter_map bridged_turn_ref_of_message existing_messages
    |> List.map Ids.Turn_ref.to_string
  in
  let _, remaining =
    List.fold_left
      (fun (seen, acc) turn_ref ->
         let key = Ids.Turn_ref.to_string turn_ref in
         if List.exists (String.equal key) seen
         then seen, acc
         else key :: seen, turn_ref :: acc)
      (already_bridged, [])
      pending
  in
  let remaining = List.rev remaining in
  match remaining with
  | [] -> Ok []
  | _ :: _ ->
    let* main, internal = read_trace_fragments ~trace_id ~session_dir in
    let bridged =
      List.concat_map
        (fun turn_ref ->
           let fragments =
             Keeper_turn_fragments.of_turn turn_ref main
             @ Keeper_turn_fragments.of_turn turn_ref internal
           in
           messages_for_turn turn_ref fragments)
        remaining
    in
    Ok bridged
;;

let render_turn_block turn_ref fragments =
  let message_lines, obs_rev =
    List.fold_left
      (fun (lines, obs) fragment ->
         match fragment with
         | Keeper_turn_fragments.Message observed ->
           let text =
             String.trim
               (Agent_core.Types.visible_text_of_content observed.message.content)
           in
           if String.equal text ""
           then lines, obs
           else
             let role_label =
               match observed.message.role with
               | Agent_core.Types.User -> "User"
               | Agent_core.Types.Assistant -> "Assistant"
               | Agent_core.Types.System -> "System"
               | Agent_core.Types.Tool -> "Tool"
             in
             (Printf.sprintf "%s: %s" role_label text :: lines), obs
         | Keeper_turn_fragments.Tool_observation { observation; _ } ->
           lines, observation :: obs)
      ([], [])
      fragments
  in
  let msg_lines = List.rev message_lines in
  let obs = List.rev obs_rev in
  let tool_lines =
    match obs with
    | [] -> []
    | _ :: _ -> [ "Tools: " ^ format_tool_observations obs ]
  in
  let body = msg_lines @ tool_lines in
  match body with
  | [] -> None
  | _ :: _ ->
    Some
      (Printf.sprintf
         "[Turn %s]\n%s"
         (Ids.Turn_ref.to_string turn_ref)
         (String.concat "\n" body))
;;

let intervening_context_for_official_resume
      ~base_path
      ~keeper_name
      ~trace_id
      ~client_kind
      ~runtime_id
      ~session_id
  =
  let* entries = read_client_turns ~base_path ~keeper_name in
  match last_settled_turn ~client_kind ~runtime_id ~session_id entries with
  | None -> Ok None
  | Some cursor ->
    let* events = read_turn_events ~base_path ~keeper_name in
    let* intervening =
      turns_after_cursor ~trace_id ~answered:(answered_by_client entries) ~cursor events
    in
    (match intervening with
     | [] -> Ok None
     | _ :: _ ->
       let session_dir =
         Filename.concat (Keeper_fs.session_store_path_for_base_path base_path) trace_id
       in
       let* main, internal = read_trace_fragments ~trace_id ~session_dir in
       let blocks =
         List.filter_map
           (fun turn_ref ->
              let fragments =
                Keeper_turn_fragments.of_turn turn_ref main
                @ Keeper_turn_fragments.of_turn turn_ref internal
              in
              render_turn_block turn_ref fragments)
           intervening
       in
       (match blocks with
        | [] -> Ok None
        | _ :: _ ->
          Ok
            (Some
               ("[Cross-runtime handoff: turns executed after this session's previous turn]\n\n"
                ^ String.concat "\n\n" blocks))))
;;

let prepend_resume_handoff
      ~input_source
      ~base_path
      ~keeper_name
      ~client_kind
      ~runtime_id
      ~session_id
      ~goal
  =
  match Keeper_request_source.trace_id input_source with
  | None -> goal
  | Some trace_id ->
    (match
       intervening_context_for_official_resume
         ~base_path
         ~keeper_name
         ~trace_id
         ~client_kind
         ~runtime_id
         ~session_id
     with
     | Ok None -> goal
     | Ok (Some handoff) -> handoff ^ "\n\n" ^ goal
     | Error err ->
       Log.Keeper.warn
         ~keeper_name
         "cross-runtime resume handoff skipped: %s"
         (bridge_load_error_to_string err);
       goal)
;;
