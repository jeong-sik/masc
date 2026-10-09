module Input = Runtime_claude_input_attribution

type evidence =
  | Explicit_group of Input.group
  | Response_inherited of Input.group
  | Command_inherited of Input.command_witness

type bound =
  { ticket : Input.ticket
  ; evidence : evidence
  ; observation : Runtime_claude_code.native_task_observation
  }

type rejection =
  | Missing_ticket
  | Conflicting_invocation
  | Foreign_session
  | Missing_assistant_evidence
  | Unattributed_assistant
  | Rejected_assistant of Input.rejection
  | Input_not_in_group
  | Conflicting_assistant_evidence

type invocation = Awaiting_ticket | Ticket of Input.ticket | Conflicted
type owner_key = string * string * int * string

type t =
  { mutable invocation : invocation
  ; envelopes : (string, (evidence, rejection) result) Hashtbl.t
  ; owners : (owner_key, (evidence, rejection) result) Hashtbl.t
  }

let create () =
  { invocation = Awaiting_ticket
  ; envelopes = Hashtbl.create 8
  ; owners = Hashtbl.create 8
  }

let same_ticket (left : Input.ticket) (right : Input.ticket) =
  String.equal left.receiver_generation right.receiver_generation
  && String.equal left.session_id right.session_id
  && String.equal left.client_uuid right.client_uuid

let frame_evidence (observation : Input.observation) =
  let contains_input (group : Input.group) =
    List.exists (String.equal observation.ticket.client_uuid) group.consumed
  in
  match observation.attribution with
  | Input.Explicit group when contains_input group -> Ok (Explicit_group group)
  | Input.Inherited group when contains_input group -> Ok (Response_inherited group)
  | Input.Command_inherited witness when contains_input witness.group ->
      Ok (Command_inherited witness)
  | Input.Explicit _ | Input.Inherited _ | Input.Command_inherited _ ->
      Error Input_not_in_group
  | Input.Unattributed -> Error Unattributed_assistant
  | Input.Rejected reason -> Error (Rejected_assistant reason)

let observe_input t (observation : Input.observation) =
  (match t.invocation with
   | Awaiting_ticket ->
       t.invocation <-
         (match observation.frame, observation.phase with
          | None, Input.Prepared -> Ticket observation.ticket
          | _ -> Conflicted)
   | Ticket ticket when not (same_ticket ticket observation.ticket) ->
       t.invocation <- Conflicted
   | Ticket _ | Conflicted -> ());
  match t.invocation, observation.frame with
  | Ticket _, Some (Input.Assistant {uuid = Some envelope; _}) ->
      let incoming = frame_evidence observation in
      (match Hashtbl.find_opt t.envelopes envelope with
       | None -> Hashtbl.add t.envelopes envelope incoming
       | Some existing when existing = incoming -> ()
       | Some (Error _) -> ()
       | Some (Ok _) ->
           Hashtbl.replace t.envelopes envelope (Error Conflicting_assistant_evidence))
  | (Awaiting_ticket | Conflicted), _
  | Ticket _, (None | Some (Input.Assistant {uuid = None; _}
      | Input.Partial_start _ | Input.Partial_fragment _ | Input.Partial_stop _
      | Input.Result _)) -> ()

let bind_task t (observation : Runtime_claude_code.native_task_observation) =
  let owner = observation.owner in
  let key = owner.session_id, owner.call_envelope_uuid, owner.call_ordinal, owner.call_id in
  let current = match t.invocation with
    | Awaiting_ticket -> Error Missing_ticket
    | Conflicted -> Error Conflicting_invocation
    | Ticket ticket ->
        if not (String.equal ticket.session_id owner.session_id) then Error Foreign_session
        else match Hashtbl.find_opt t.envelopes owner.call_envelope_uuid with
          | None -> Error Missing_assistant_evidence
          | Some evidence -> evidence
  in
  let evidence = match Hashtbl.find_opt t.owners key with
    | None -> Hashtbl.add t.owners key current; current
    | Some (Error _ as rejected) -> rejected
    | Some (Ok frozen) ->
        (* A later conflict cannot rewrite delivered facts, but also cannot
           silently authorize further observations of an ambiguous owner. *)
        (match current with Error _ as rejected -> rejected | Ok _ -> Ok frozen)
  in
  match t.invocation, evidence with
  | Ticket ticket, Ok evidence -> Ok {ticket; evidence; observation}
  | (Awaiting_ticket | Ticket _ | Conflicted), Error reason -> Error reason
  | Awaiting_ticket, Ok _ -> Error Missing_ticket
  | Conflicted, Ok _ -> Error Conflicting_invocation

let rejection_to_string = function
  | Missing_ticket -> "no invocation input ticket"
  | Conflicting_invocation -> "conflicting invocation input ticket"
  | Foreign_session -> "native task belongs to another input session"
  | Missing_assistant_evidence -> "no input evidence for the native assistant envelope"
  | Unattributed_assistant -> "native assistant envelope has no input attribution"
  | Rejected_assistant _ -> "native assistant input attribution was rejected"
  | Input_not_in_group -> "native assistant attribution does not contain this input"
  | Conflicting_assistant_evidence -> "conflicting native assistant input evidence"
