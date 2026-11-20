(* Causal turn bridging across runtime switches. See [keeper_turn_bridge.mli]
   for the contract. *)

open Result.Syntax

let bridged_turn_ref_metadata_key = "masc.bridged_turn_ref"
let cursor_store_schema = "masc.keeper.official-client-bridge-cursors.v1"

type bridge_load_error =
  | Boundary_log_unreadable of string
  | Boundary_line_unreadable of
      { line : int
      ; error : Keeper_turn_boundaries.read_error
      }
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
  | Cursor_store_invalid of string

let fragment_file_label = function
  | Keeper_turn_fragments.Main -> "history.jsonl"
  | Keeper_turn_fragments.Internal -> "history.internal.jsonl"
;;

let bridge_load_error_to_string = function
  | Boundary_log_unreadable detail ->
    "turn boundary log unreadable: " ^ detail
  | Boundary_line_unreadable { line; error } ->
    Printf.sprintf
      "turn boundary line %d unreadable: %s"
      line
      (Keeper_turn_boundaries.read_error_to_string error)
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
  | Cursor_store_invalid detail ->
    "official-client bridge cursor store invalid: " ^ detail
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

type cursor =
  { client_kind : Keeper_semantic_execution.official_client_kind
  ; runtime_id : string
  ; session_id : string
  ; last_turn_ref : Ids.Turn_ref.t
  ; last_boundary_line : int
  ; updated_at : float
  }

let cursor_key_equal
      cursor
      ~(client_kind : Keeper_semantic_execution.official_client_kind)
      ~runtime_id
      ~session_id
  =
  cursor.client_kind = client_kind
  && String.equal cursor.runtime_id runtime_id
  && String.equal cursor.session_id session_id
;;

let validate_cursor cursor =
  if String.trim cursor.runtime_id = ""
  then Error "bridge cursor runtime_id must not be blank"
  else if String.trim cursor.session_id = ""
  then Error "bridge cursor session_id must not be blank"
  else if cursor.last_boundary_line < 1
  then Error "bridge cursor last_boundary_line must be positive"
  else if not (Float.is_finite cursor.updated_at)
  then Error "bridge cursor updated_at must be finite"
  else Ok ()
;;

let cursor_to_yojson cursor =
  `Assoc
    [ ( "client_kind"
      , `String
          (Keeper_semantic_execution.official_client_kind_to_string cursor.client_kind)
      )
    ; "last_boundary_line", `Int cursor.last_boundary_line
    ; "last_turn_ref", `String (Ids.Turn_ref.to_string cursor.last_turn_ref)
    ; "runtime_id", `String cursor.runtime_id
    ; "session_id", `String cursor.session_id
    ; "updated_at", `Float cursor.updated_at
    ]
;;

let cursor_of_yojson = function
  | `Assoc fields ->
    (match
       List.sort (fun (left, _) (right, _) -> String.compare left right) fields
     with
     | [ "client_kind", `String kind_raw
       ; "last_boundary_line", `Int last_boundary_line
       ; "last_turn_ref", `String turn_ref_raw
       ; "runtime_id", `String runtime_id
       ; "session_id", `String session_id
       ; "updated_at", `Float updated_at
       ] ->
       let* client_kind =
         match Keeper_semantic_execution.official_client_kind_of_string kind_raw with
         | Some kind -> Ok kind
         | None -> Error ("unknown bridge cursor client_kind: " ^ kind_raw)
       in
       let* last_turn_ref =
         match Ids.Turn_ref.of_string turn_ref_raw with
         | Some turn_ref -> Ok turn_ref
         | None -> Error ("invalid bridge cursor last_turn_ref: " ^ turn_ref_raw)
       in
       let cursor =
         { client_kind
         ; runtime_id
         ; session_id
         ; last_turn_ref
         ; last_boundary_line
         ; updated_at
         }
       in
       let* () = validate_cursor cursor in
       Ok cursor
     | _ -> Error "bridge cursor entry fields are not exact")
  | _ -> Error "bridge cursor entry must be a JSON object"
;;

let cursors_to_yojson cursors =
  `Assoc
    [ "cursors", `List (List.map cursor_to_yojson cursors)
    ; "schema", `String cursor_store_schema
    ]
;;

let cursors_of_yojson = function
  | `Assoc fields ->
    (match
       List.sort (fun (left, _) (right, _) -> String.compare left right) fields
     with
     | [ "cursors", `List items; "schema", `String schema ]
       when String.equal schema cursor_store_schema ->
       let rec decode_all acc = function
         | [] -> Ok (List.rev acc)
         | item :: rest ->
           let* cursor = cursor_of_yojson item in
           decode_all (cursor :: acc) rest
       in
       decode_all [] items
     | [ "cursors", `List _; "schema", `String schema ] ->
       Error ("unsupported bridge cursor store schema: " ^ schema)
     | _ -> Error "bridge cursor store fields are not exact")
  | _ -> Error "bridge cursor store must be a JSON object"
;;

let load_cursors_from_path path =
  match Fs_compat.load_file_opt path with
  | None -> Ok []
  | Some raw ->
    let* json = Safe_ops.parse_json_off_fiber ~context:"keeper_turn_bridge.cursors" raw in
    cursors_of_yojson json
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

let pending_uncheckpointed_turn_refs ~trace_id lines =
  let pending_rev, bad_tail_line =
    List.fold_left
      (fun (pending_rev, bad_tail) (line_num, decoded) ->
         match decoded with
         | Error Keeper_turn_boundaries.Incomplete_line -> pending_rev, bad_tail
         | Error ((Keeper_turn_boundaries.Not_json _ | Keeper_turn_boundaries.Malformed _) as error) ->
           let bad_tail =
             match bad_tail with
             | Some _ -> bad_tail
             | None -> Some (line_num, error)
           in
           pending_rev, bad_tail
         | Ok (record : Keeper_turn_boundaries.record) ->
           (match record.event with
            | Keeper_turn_boundaries.History_restarted { trace_id = restarted } ->
              if String.equal restarted trace_id
              then [], None
              else pending_rev, bad_tail
            | Keeper_turn_boundaries.Turn_ended { turn_ref; history_at_start = _; position } ->
              if not (String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id)
              then pending_rev, bad_tail
              else (
                match position with
                | Keeper_turn_boundaries.Atom_history _
                | Keeper_turn_boundaries.Empty_atom_history ->
                  [], None
                | Keeper_turn_boundaries.Stale_noop ->
                  pending_rev, bad_tail
                | Keeper_turn_boundaries.No_atom_history ->
                  turn_ref :: pending_rev, bad_tail)))
      ([], None)
      lines
  in
  match bad_tail_line with
  | Some (line, error) -> Error (Boundary_line_unreadable { line; error })
  | None -> Ok (List.rev pending_rev)
;;

let uncheckpointed_official_turns
      ~keepers_dir
      ~keeper_name
      ~trace_id
      ~session_dir
      ~existing_messages
  =
  let* lines =
    Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:keeper_name
    |> Result.map_error (fun detail -> Boundary_log_unreadable detail)
  in
  let* pending = pending_uncheckpointed_turn_refs ~trace_id lines in
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

let find_turn_boundary_line ~turn_ref lines =
  List.fold_left
    (fun found (line_num, decoded) ->
       match decoded with
       | Ok ({ Keeper_turn_boundaries.event = Keeper_turn_boundaries.Turn_ended { turn_ref = line_ref; _ }; _ })
         when Ids.Turn_ref.equal line_ref turn_ref ->
         Some line_num
       | Ok { Keeper_turn_boundaries.event = Keeper_turn_boundaries.Turn_ended _; _ }
       | Ok { Keeper_turn_boundaries.event = Keeper_turn_boundaries.History_restarted _; _ }
       | Error _ -> found)
    None
    lines
;;

let record_official_client_settlement
      ~base_path
      ~keeper_name
      ~turn_ref
      ~client_kind
      ~runtime_id
      ~session_id
      ~updated_at
  =
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let* lines = Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:keeper_name in
  match find_turn_boundary_line ~turn_ref lines with
  | None ->
    Error
      (Printf.sprintf
         "turn boundary line not found for settled official-client turn %s"
         (Ids.Turn_ref.to_string turn_ref))
  | Some last_boundary_line ->
    let cursor =
      { client_kind
      ; runtime_id
      ; session_id
      ; last_turn_ref = turn_ref
      ; last_boundary_line
      ; updated_at
      }
    in
    let* () = validate_cursor cursor in
    let* cursors_path =
      Keeper_official_client_session_store.bridge_cursors_path ~base_path ~keeper_name
    in
    let state_dir = Filename.dirname cursors_path in
    (try
       let (_ : string) = Keeper_fs.ensure_dir state_dir in
       Ok ()
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
    |> fun dir_res ->
    let* () = dir_res in
    let lock_path = state_dir ^ ".lock" in
    (match
       File_lock_eio.with_durable_lock ~lock_path (fun () ->
         let* existing = load_cursors_from_path cursors_path in
         let retained =
           List.filter
             (fun entry -> not (cursor_key_equal entry ~client_kind ~runtime_id ~session_id))
             existing
         in
         let next = retained @ [ cursor ] in
         Keeper_fs.save_json_durable_atomic
           ~ownership_root:state_dir
           ~pretty:false
           cursors_path
           (cursors_to_yojson next)
         |> Result.map_error Keeper_fs.durable_write_error_to_string)
     with
     | Ok res -> res
     | Error lock_err -> Error (File_lock_eio.durable_lock_error_to_string lock_err))
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
  let* cursors_path =
    Keeper_official_client_session_store.bridge_cursors_path ~base_path ~keeper_name
    |> Result.map_error (fun detail -> Cursor_store_invalid detail)
  in
  let* cursors =
    load_cursors_from_path cursors_path
    |> Result.map_error (fun detail -> Cursor_store_invalid detail)
  in
  match
    List.find_opt
      (cursor_key_equal ~client_kind ~runtime_id ~session_id)
      cursors
  with
  | None -> Ok None
  | Some cursor ->
    let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
    let* lines =
      Keeper_turn_boundaries.read ~keepers_dir ~keeper_id:keeper_name
      |> Result.map_error (fun detail -> Boundary_log_unreadable detail)
    in
    let beyond =
      List.filter (fun (line_num, _) -> line_num > cursor.last_boundary_line) lines
    in
    let intervening_rev, bad_tail =
      List.fold_left
        (fun (turns_rev, bad_tail) (line_num, decoded) ->
           match decoded with
           | Error Keeper_turn_boundaries.Incomplete_line -> turns_rev, bad_tail
           | Error ((Keeper_turn_boundaries.Not_json _ | Keeper_turn_boundaries.Malformed _) as error) ->
             let bad_tail =
               match bad_tail with
               | Some _ -> bad_tail
               | None -> Some (line_num, error)
             in
             turns_rev, bad_tail
           | Ok (record : Keeper_turn_boundaries.record) ->
             (match record.event with
              | Keeper_turn_boundaries.History_restarted { trace_id = restarted } ->
                if String.equal restarted trace_id
                then [], None
                else turns_rev, bad_tail
              | Keeper_turn_boundaries.Turn_ended { turn_ref; _ } ->
                if String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
                   && not (Ids.Turn_ref.equal turn_ref cursor.last_turn_ref)
                then turn_ref :: turns_rev, bad_tail
                else turns_rev, bad_tail))
        ([], None)
        beyond
    in
    let* () =
      match bad_tail with
      | Some (line, error) -> Error (Boundary_line_unreadable { line; error })
      | None -> Ok ()
    in
    let intervening = List.rev intervening_rev in
    match intervening with
    | [] -> Ok None
    | _ :: _ ->
      let session_dir =
        Filename.concat
          (Keeper_fs.session_store_path_for_base_path base_path)
          trace_id
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
      match blocks with
      | [] -> Ok None
      | _ :: _ ->
        Ok
          (Some
             ("[Cross-runtime handoff: turns executed after this session's previous turn]\n\n"
              ^ String.concat "\n\n" blocks))
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
