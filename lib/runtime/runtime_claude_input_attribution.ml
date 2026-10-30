type ticket =
  { receiver_generation : string; session_id : string; client_uuid : string }
type group = { primary : string; consumed : string list }
type rejection =
  | Duplicate_field | Invalid_primary | Invalid_group | Group_without_primary
  | Primary_not_in_group | Duplicate_member | Group_exceeds_provider_limit
  | Missing_frame_uuid | Foreign_session | Conflicting_frame_replay | Ambiguous_response
type command_witness = { group : group; stamp_uuid : string }
type attribution = Unattributed | Explicit of group | Inherited of group
  | Command_inherited of command_witness | Rejected of rejection

(* Claude Code 2.1.292 SDK consumed-input schema: at most 64 entries. This is
   the producer's group bound, not a Keeper turn or runtime budget. *)
let provider_group_limit = 64

let decode fields =
  let names = List.map fst fields in
  if List.length names <> List.length (List.sort_uniq String.compare names)
  then Rejected Duplicate_field
  else
    let primary = List.assoc_opt "user_message_uuid" fields in
    let plural = List.assoc_opt "user_message_uuids" fields in
    match primary, plural with
    | None, None -> Unattributed
    | None, Some _ -> Rejected Group_without_primary
    | Some (`String primary), plural when primary <> "" ->
        (match plural with
         | None -> Explicit {primary; consumed=[primary]}
         | Some (`List values) ->
             if List.length values > provider_group_limit then Rejected Group_exceeds_provider_limit
             else
               let rec members acc = function
                 | [] -> Ok (List.rev acc)
                 | `String value :: rest when value <> "" ->
                     if List.mem value acc then Error Duplicate_member
                     else members (value :: acc) rest
                 | _ :: _ -> Error Invalid_group in
               (match members [] values with
                | Error reason -> Rejected reason
                | Ok consumed when not (List.mem primary consumed) -> Rejected Primary_not_in_group
                | Ok consumed -> Explicit {primary;consumed})
         | Some _ -> Rejected Invalid_group)
    | Some _, _ -> Rejected Invalid_primary

type outcome = Provider_success | Provider_error
type phase = Prepared | Written | Write_unknown | Consumed | Settled of outcome
type frame =
  | Partial_start of { uuid : string option; message_id : string }
  | Partial_fragment of { uuid : string option }
  | Partial_stop of { uuid : string option }
  | Assistant of { uuid : string option; message_id : string option }
  | Result of { uuid : string option; outcome : outcome option }
type observation =
  { ticket : ticket; phase : phase; frame : frame option; attribution : attribution }

type response = { mutable attribution : attribution }
type response_binding = Unique of response | Ambiguous
type seen = { frame : frame; stamp : attribution; response : response option }
type command_scope = Awaiting_witness | Witnessed of command_witness | Suspended | Ended
type write_fact = Unwritten | Write_completed | Write_unconfirmed
type response_scope = Clear_scope | Uncertain_scope
type t =
  { ticket : ticket
  ; mutable phase : phase
  ; mutable current : response option
  ; mutable command : command_scope
  ; mutable write_fact : write_fact
  ; mutable response_scope : response_scope
  ; responses : (string, response_binding) Hashtbl.t
  ; seen : (string, seen) Hashtbl.t
  }

let create ~receiver_generation ~session_id ~client_uuid =
  { ticket={receiver_generation;session_id;client_uuid}; phase=Prepared; current=None
  ; command=Awaiting_witness; write_fact=Unwritten; response_scope=Clear_scope
  ; responses=Hashtbl.create 8; seen=Hashtbl.create 16 }
let ticket t = t.ticket
let user_message t ~content =
  `Assoc ["uuid", `String t.ticket.client_uuid; "type", `String "user";
    "message", `Assoc ["role", `String "user"; "content", `List content];
    "parent_tool_use_id", `Null; "session_id", `String "default"]
let snapshot t frame attribution = {ticket=t.ticket;phase=t.phase;frame;attribution}
let prepared t = snapshot t None Unattributed
let written t =
  (match t.phase with Prepared -> t.phase <- Written; t.write_fact <- Write_completed
   | Written | Write_unknown | Consumed | Settled _ -> ());
  snapshot t None Unattributed
let write_unknown t =
  (match t.phase with Prepared -> t.phase <- Write_unknown; t.write_fact <- Write_unconfirmed
   | Written | Write_unknown | Consumed | Settled _ -> ());
  snapshot t None Unattributed

let uuid = function
  | Partial_start {uuid;_} | Partial_fragment {uuid} | Partial_stop {uuid}
  | Assistant {uuid;_} | Result {uuid;_} -> uuid

let response_for t = function
  | Partial_start {message_id;_} ->
      let response = {attribution=Unattributed} in
      let binding = if Hashtbl.mem t.responses message_id then Ambiguous else Unique response in
      Hashtbl.replace t.responses message_id binding;
      t.current <- Some response;
      t.response_scope <- Clear_scope;
      Some response
  | Partial_fragment _ | Partial_stop _ -> t.current
  | Assistant {message_id=Some id;_} ->
      (* A complete envelope has a message id but no occurrence generation.
         Once an ID is reused, it cannot choose either occurrence by recency. *)
      (match Hashtbl.find_opt t.responses id with
       | Some (Unique response) -> Some response
       | Some Ambiguous | None -> None)
  | Assistant {message_id=None;_} | Result _ -> None

let suspend_command t =
  match t.command with
  | Awaiting_witness | Witnessed _ | Suspended -> t.command <- Suspended
  | Ended -> ()

let observe_command t frame uuid stamp =
  match frame with
  | Result _ -> () (* [observe] closes the command before any admission branch. *)
  | Partial_start _ | Partial_fragment _ | Partial_stop _ | Assistant _ ->
      match stamp with
      | Explicit group when group.primary=t.ticket.client_uuid ->
          (match t.command, t.write_fact with
           | (Awaiting_witness | Witnessed _ | Suspended), Write_completed ->
               t.command <- Witnessed {group;stamp_uuid=uuid}
           | Ended, _ | _, (Unwritten | Write_unconfirmed) -> ())
      | Explicit _ | Rejected _ -> suspend_command t
      | Unattributed | Inherited _ | Command_inherited _ -> ()

let available_command t =
  match t.command, t.response_scope with
  | Witnessed witness, Clear_scope -> Some witness
  | (Awaiting_witness | Suspended | Ended), (Clear_scope | Uncertain_scope)
  | Witnessed _, Uncertain_scope -> None

let command_inheritance t =
  match available_command t with
  | Some witness -> Command_inherited witness
  | None -> Unattributed

let resolve t frame response stamp =
  match stamp with
  | Explicit _ | Rejected _ ->
      (match t.command with
       | Awaiting_witness | Witnessed _ | Suspended ->
           Option.iter (fun response -> response.attribution <- stamp) response
       | Ended -> ());
      stamp
  | Inherited _ | Command_inherited _ -> stamp (* [decode] produces neither. *)
  | Unattributed ->
      if t.command=Ended then Unattributed else
      let inherited = match response with
        | Some {attribution=(Explicit group | Inherited group);_} -> Inherited group
        | Some {attribution=Command_inherited witness;_} ->
            (match available_command t with
             | Some _ -> Command_inherited witness
             | None -> Unattributed)
        | Some {attribution=Rejected reason;_} -> Rejected reason
        | Some {attribution=Unattributed;_} -> command_inheritance t
        | None ->
            match frame with
            | Assistant {message_id=Some id;_} ->
                (match Hashtbl.find_opt t.responses id with
                 | Some Ambiguous ->
                     (* This proof names the SDK command, not either response
                        occurrence sharing the provider's model ID. *)
                     (match available_command t with
                      | Some witness -> Command_inherited witness
                      | None -> Rejected Ambiguous_response)
                 | Some (Unique _) | None -> command_inheritance t)
            | Assistant {message_id=None;_} -> command_inheritance t
            | Partial_start _ | Partial_fragment _ | Partial_stop _ | Result _ -> Unattributed in
      (* A fresh response keeps its actual command witness snapshot; a later
         observed fold never fabricates new members in this older response. *)
      Option.iter (fun response -> response.attribution <- inherited) response;
      inherited

let advance t frame attribution =
  match attribution with
  | Unattributed | Rejected _ -> ()
  | Explicit group | Inherited group | Command_inherited {group;_} ->
      if List.mem t.ticket.client_uuid group.consumed then
        match t.phase with
        | Prepared | Settled _ -> ()
        | Written | Write_unknown | Consumed ->
            (match frame, attribution with
             | Result {outcome=Some outcome;_}, Explicit _ -> t.phase <- Settled outcome
             | Result {outcome=None;_}, Explicit _
             | (Partial_start _ | Partial_fragment _ | Partial_stop _ | Assistant _), _ ->
                 t.phase <- Consumed
             | Result _, (Unattributed | Inherited _ | Command_inherited _ | Rejected _) -> ())

let quarantine t frame reason =
  suspend_command t;
  t.response_scope <- Uncertain_scope;
  let invalidate response = response.attribution <- Rejected reason in
  match frame with
  | Partial_start {message_id;_} ->
      t.current <- None;
      Hashtbl.replace t.responses message_id Ambiguous
  | Partial_fragment _ -> Option.iter invalidate t.current
  | Partial_stop _ -> Option.iter invalidate t.current; t.current <- None
  | Assistant {message_id=Some id;_} ->
      (match Hashtbl.find_opt t.responses id with
       | Some (Unique response) -> invalidate response
       | Some Ambiguous | None -> ())
  | Assistant {message_id=None;_} | Result _ -> ()

let unowned_response_start t ~message_id =
  t.response_scope <- Uncertain_scope;
  t.current <- None;
  Hashtbl.replace t.responses message_id Ambiguous

let observe t ~session_id ~frame fields =
  if session_id <> t.ticket.session_id then
    Some (snapshot t (Some frame) (Rejected Foreign_session))
  else begin
    (* This boundary ends the SDK command even if its optional attribution or
       envelope identity is rejected. It does not settle a ticket by itself. *)
    (match frame with Result _ -> t.command <- Ended; t.current <- None
     | Partial_start _ | Partial_fragment _ | Partial_stop _ | Assistant _ -> ());
    let stamp = decode fields in
    match uuid frame with
    | None | Some "" ->
        quarantine t frame Missing_frame_uuid;
        Some (snapshot t (Some frame) (Rejected Missing_frame_uuid))
    | Some uuid ->
        match Hashtbl.find_opt t.seen uuid with
        | Some previous when previous.frame = frame && previous.stamp = stamp ->
            (* The content parser moves its message cursor on a replayed
               start. An exact historical stop, however, is a parser no-op
               and belongs to its original occurrence, not the current one. *)
            (match frame with
             | Partial_start {message_id;_} ->
                 (match t.current, previous.response with
                  | Some current, Some original when current == original -> ()
                  | Some _, Some _ | Some _, None | None, (Some _ | None) ->
                      (* A stale root replay contradicts the active response;
                         unlike a child start it also suspends command proof. *)
                      suspend_command t;
                      unowned_response_start t ~message_id)
             | Partial_stop _ | Partial_fragment _ | Assistant _ | Result _ -> ());
            None
        | Some previous ->
            Option.iter (fun response -> response.attribution <- Rejected Conflicting_frame_replay)
              previous.response;
            quarantine t frame Conflicting_frame_replay;
            Some (snapshot t (Some frame) (Rejected Conflicting_frame_replay))
        | None ->
            let response = response_for t frame in
            Hashtbl.add t.seen uuid {frame;stamp;response};
            observe_command t frame uuid stamp;
            let attribution = resolve t frame response stamp in
            advance t frame attribution;
            (match frame with Partial_stop _ -> t.current <- None
             | Partial_start _ | Partial_fragment _ | Assistant _ | Result _ -> ());
            Some (snapshot t (Some frame) attribution)
  end
