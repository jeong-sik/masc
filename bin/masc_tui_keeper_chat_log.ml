module Live = Masc_tui_keeper_chat_live
module E = Masc.Keeper_chat_events
module Journal = Masc.Keeper_chat_event_log

type entry =
  { seq : int option
  ; attempt : int
  ; delta : Live.delta
  }

type t =
  { keeper_name : string
  ; request_id : string
  ; started_at : float
  ; mutable reversed_entries : entry list
  ; held_seqs : (int, unit) Hashtbl.t
  ; mutable last_seq : int
  ; mutable attempt : int
  ; mutable committed : bool
  ; mutable revision : int
  }

let create ~keeper_name ~request_id ~started_at =
  { keeper_name
  ; request_id
  ; started_at
  ; reversed_entries = []
  ; held_seqs = Hashtbl.create 64
  ; last_seq = -1
  ; attempt = 0
  ; committed = false
  ; revision = 0
  }

let keeper_name t = t.keeper_name
let request_id t = t.request_id
let started_at t = t.started_at
let entries t = List.rev t.reversed_entries
let last_seq t = t.last_seq
let attempt t = t.attempt
let committed t = t.committed
let revision t = t.revision

let bump t = t.revision <- t.revision + 1

let add t ~seq (delta : Live.delta) =
  let duplicate =
    match seq with
    | Some seq -> Hashtbl.mem t.held_seqs seq
    | None -> false
  in
  if duplicate
  then false
  else begin
    (match delta with
     | Live.Runtime_attempt_started -> t.attempt <- t.attempt + 1
     | Live.Run_started | Live.Text _ | Live.Thinking _ | Live.Tool_started _
     | Live.Tool_args _ | Live.Tool_ended _ | Live.Tool_result _
     | Live.Stream_protocol_error _ | Live.Approval_requested _
     | Live.Approval_settled _ | Live.Accepted _ | Live.Checkpoint
     | Live.External_effect_completed | Live.Reply_details _ | Live.Run_failed _
     | Live.Run_finished | Live.Undecodable _ -> ());
    (match seq with
     | Some seq ->
       Hashtbl.replace t.held_seqs seq ();
       if seq > t.last_seq then t.last_seq <- seq
     | None -> ());
    t.reversed_entries <- { seq; attempt = t.attempt; delta } :: t.reversed_entries;
    bump t;
    true
  end
;;

let commit t =
  if not t.committed
  then begin
    t.committed <- true;
    bump t
  end
;;

(* The server-side occurrence carries no tool_call_id of its own; the event
   that owns the occurrence does, and the wire sends both on the same frame. *)
let occurrence (occurrence : E.tool_stream_occurrence) ~tool_call_id : Live.tool_occurrence =
  { stream_scope = occurrence.stream_scope
  ; block_index = occurrence.block_index
  ; provider_message_id = occurrence.provider_message_id
  ; tool_call_id
  }
;;

(* Same composition as the live decoder's KEEPER_STREAM_PROTOCOL_ERROR arm:
   "<kind>: <reason>" when a nonblank reason was sent, else the kind alone. *)
let protocol_error_detail (error : E.stream_protocol_error) =
  let kind = E.stream_protocol_error_kind_to_string error.kind in
  match error.reason with
  | Some reason when String.trim reason <> "" -> kind ^ ": " ^ reason
  | Some _ | None -> kind
;;

let delta_of_journaled (event : E.keeper_chat_event) : Live.delta option =
  match event with
  | E.Run_started _ -> Some Live.Run_started
  | E.Text_message_start _ | E.Text_message_end -> None
  | E.Text_delta text -> Some (Live.Text text)
  | E.External_effect_completed _ -> Some Live.External_effect_completed
  | E.Run_finished _ -> Some Live.Run_finished
  | E.Event_error { message } -> Some (Live.Run_failed { message })
  | E.Reply_details { reply; turn_outcome; turn_ref } ->
    Some
      (Live.Reply_details
         { reply; turn_outcome; turn_ref = Ids.Turn_ref.to_string turn_ref })
  | E.Continuation_checkpoint _ -> Some Live.Checkpoint
  | E.Agent_core_stream_connected -> None
  | E.Agent_core_runtime_attempt_started -> Some Live.Runtime_attempt_started
  | E.Agent_core_stream_message_start _
  | E.Agent_core_stream_message_delta _
  | E.Agent_core_stream_message_stop
  | E.Agent_core_stream_ping
  | E.Agent_core_content_block_start _
  | E.Agent_core_content_block_stop _ -> None
  | E.Agent_core_thinking_delta { delta; _ } -> Some (Live.Thinking delta)
  | E.Agent_core_thinking_signature_delta _ | E.Agent_core_media_delta _ -> None
  | E.Agent_core_stream_protocol_error error ->
    Some
      (Live.Stream_protocol_error
         { quarantined_occurrence =
             Option.map
               (fun quarantined -> occurrence quarantined ~tool_call_id:None)
               error.quarantined_occurrence
         ; detail = protocol_error_detail error
         })
  | E.Tool_call_start { occurrence = o; tool_call_id; tool_call_name } ->
    Some
      (Live.Tool_started
         { occurrence = occurrence o ~tool_call_id; tool_name = tool_call_name })
  | E.Tool_call_args { occurrence = o; tool_call_id; delta } ->
    Some
      (Live.Tool_args
         { occurrence = occurrence o ~tool_call_id; fragment = Live.Args_delta delta })
  | E.Tool_call_args_snapshot { occurrence = o; tool_call_id; snapshot } ->
    Some
      (Live.Tool_args
         { occurrence = occurrence o ~tool_call_id
         ; fragment = Live.Args_snapshot snapshot
         })
  | E.Tool_call_end { occurrence = o; tool_call_id } ->
    Some (Live.Tool_ended { occurrence = occurrence o ~tool_call_id })
  | E.Tool_approval_requested { tool_call_id; tool_call_name; args; question; because } ->
    Some
      (Live.Approval_requested
         { call_id = tool_call_id; tool_name = tool_call_name; args; question; because })
  | E.Tool_approval_settled { tool_call_id; outcome } ->
    Some (Live.Approval_settled { call_id = tool_call_id; outcome })
  | E.Tool_result_ready { occurrence = o; tool_call_id; execution_id } ->
    Some
      (Live.Tool_result
         { occurrence = occurrence o ~tool_call_id
         ; execution_id = Ids.Execution_id.to_string execution_id
         })
  | E.Link_block _ | E.Image_block _ | E.Status_block _ | E.Audio_block _
  | E.Tool_context_block _ -> None
;;

(* Nothing to draw, so no entry and no revision bump; the position is still
   held so a later live frame with this seq is a duplicate and a resume asks
   past it. *)
let hold_seq t seq =
  if not (Hashtbl.mem t.held_seqs seq)
  then begin
    Hashtbl.replace t.held_seqs seq ();
    if seq > t.last_seq then t.last_seq <- seq
  end
;;

(* The one fold of a journal page into a log. What it returns is what the
   caller's projection has to follow: the lines whose delta the log took, in
   journal order, so a transcript kept as the fold of the log can apply
   exactly those, each at its line's own time. A line already held by seq,
   and a line that draws nothing, are not in it. *)
let add_journaled t (lines : Journal.journaled_event list) =
  List.fold_left
    (fun taken (line : Journal.journaled_event) ->
       match delta_of_journaled line.event with
       | None ->
         hold_seq t line.seq;
         taken
       | Some delta ->
         if add t ~seq:(Some line.seq) delta then (line, delta) :: taken else taken)
    []
    lines
  |> List.rev
;;

type events_page =
  { operation_id : string
  ; events : Journal.journaled_event list
  ; has_more : bool
  ; next_since_seq : int
  }

let events_schema = "masc.keeper_chat_events.v2"

let decode_events_page (json : Yojson.Safe.t) =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
    let* () =
      match List.assoc_opt "schema" fields with
      | Some (`String schema) when String.equal schema events_schema -> Ok ()
      | Some (`String schema) -> Error ("unexpected events schema: " ^ schema)
      | Some _ | None -> Error "events body has no schema"
    in
    let* operation_id =
      match List.assoc_opt "operation_id" fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None -> Error "events body has no operation_id"
    in
    let* has_more =
      match List.assoc_opt "has_more" fields with
      | Some (`Bool value) -> Ok value
      | Some _ | None -> Error "events body has no boolean has_more"
    in
    let* next_since_seq =
      match List.assoc_opt "next_since_seq" fields with
      | Some (`Int value) -> Ok value
      | Some _ | None -> Error "events body has no integer next_since_seq"
    in
    let* raw_events =
      match List.assoc_opt "events" fields with
      | Some (`List events) -> Ok events
      | Some _ | None -> Error "events body has no events list"
    in
    let* events =
      List.fold_left
        (fun acc raw ->
           let* acc = acc in
           let* event = Journal.journaled_event_of_json raw in
           Ok (event :: acc))
        (Ok [])
        raw_events
      |> Result.map List.rev
    in
    Ok { operation_id; events; has_more; next_since_seq }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Error "events body is not an object"
;;

type events_error =
  | Unknown_operation
  | Journal_pruned
  | Journal_unavailable of string
  | Events_refused of string
  | Events_undecodable of string
  | Events_transport of string

let events_error_to_string = function
  | Unknown_operation -> "unknown operation"
  | Journal_pruned -> "journal pruned"
  | Journal_unavailable detail -> "journal unavailable: " ^ detail
  | Events_refused detail -> "events request refused: " ^ detail
  | Events_undecodable detail -> "events body unreadable: " ^ detail
  | Events_transport detail -> "events request failed: " ^ detail
;;

(* The error envelope is [masc.keeper_chat_operation.error.v1]:
   [{schema; error = <code>; message}]. The code is the typed fact; the
   message is what the server said, kept only where the code alone does not
   tell the pane what to do. A 401/403 is about this client's credential, not
   about the journal, and is said the way every other refused request is. *)
let decode_events_error ~status ~credential_sent body =
  let rejected detail = Events_undecodable (Printf.sprintf "%d %s" status detail) in
  if status = 401 || status = 403
  then Events_refused (Masc_tui_credential.refusal ~credential_sent)
  else
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    let message =
      match List.assoc_opt "message" fields with
      | Some (`String message) -> message
      | Some _ | None -> body
    in
    (match List.assoc_opt "error" fields with
     | Some (`String "unknown_operation") -> Unknown_operation
     | Some (`String "journal_pruned") -> Journal_pruned
     | Some (`String ("journal_unreadable" | "journal_corrupt")) ->
       Journal_unavailable message
     | Some (`String _) | Some _ | None -> rejected message)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    rejected body
  | exception Yojson.Json_error _ -> rejected body
;;

(* A whole journal, page by page, through the caller's fetch. [since_seq] is
   where to start ([-1] for the whole journal, a held log's [last_seq] to read
   only what it lacks). The loop follows [has_more] while [next_since_seq]
   advances. A page that claims more without advancing would be read
   forever, and the lines read so far are not the journal: such a read is
   an error naming the position, not a shorter [Ok]. *)
let read_whole_journal ~fetch ~since_seq =
  let rec page since_seq acc =
    match fetch ~since_seq with
    | Error error -> Error error
    | Ok { events; has_more; next_since_seq; _ } ->
      let acc = List.rev_append events acc in
      if not has_more
      then Ok (List.rev acc)
      else if next_since_seq > since_seq
      then page next_since_seq acc
      else
        Error
          (Events_undecodable
             (Printf.sprintf
                "page after seq %d claims more but did not advance (next_since_seq %d)"
                since_seq
                next_since_seq))
  in
  page since_seq []
;;
