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

type bound_parent =
  { ticket : Input.ticket
  ; evidence : evidence
  ; parent : Runtime_claude_code.native_agent_parent_witness
  }

type bound_child =
  { parent_input : bound_parent
  ; content : Runtime_claude_code.complete_child_content
  }

type rejection =
  | Missing_ticket
  | Conflicting_invocation
  | Foreign_session
  | Foreign_invocation
  | Unknown_parent
  | Conflicting_parent_provenance
  | Missing_assistant_evidence
  | Unattributed_assistant
  | Rejected_assistant of Input.rejection
  | Input_not_in_group
  | Conflicting_assistant_evidence

type child_observation =
  | Child_bound of bound_child
  | Child_rejected of
      { content : Runtime_claude_code.complete_child_content
      ; reason : rejection
      }

type invocation = Awaiting_ticket | Ticket of Input.ticket | Conflicted
type owner_key = Input.ticket * string * int * string

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

let check_invocation t (invocation : Input.ticket) =
  match t.invocation with
    | Ticket ticket when not (String.equal ticket.session_id invocation.session_id) ->
        Error Foreign_session
    | Ticket ticket when not (same_ticket ticket invocation) -> Error Foreign_invocation
    | Awaiting_ticket | Conflicted | Ticket _ -> Ok ()

let bind_owner t ~(invocation : Input.ticket) ~call_envelope_uuid ~call_ordinal ~call_id =
  let ( let* ) = Result.bind in
  (* Refuse captured observations from another runtime before touching the
     current owner's cache, even when all provider/session IDs were replayed. *)
  let* () = check_invocation t invocation in
  let key = invocation, call_envelope_uuid, call_ordinal, call_id in
  let current = match t.invocation with
    | Awaiting_ticket -> Error Missing_ticket
    | Conflicted -> Error Conflicting_invocation
    | Ticket _ ->
        match Hashtbl.find_opt t.envelopes call_envelope_uuid with
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
  | Ticket ticket, Ok evidence -> Ok (ticket, evidence)
  | (Awaiting_ticket | Ticket _ | Conflicted), Error reason -> Error reason
  | Awaiting_ticket, Ok _ -> Error Missing_ticket
  | Conflicted, Ok _ -> Error Conflicting_invocation

let bind_task t (observation : Runtime_claude_code.native_task_observation) =
  let owner = observation.owner in
  let ( let* ) = Result.bind in
  let* ticket, evidence = bind_owner t ~invocation:owner.invocation
    ~call_envelope_uuid:owner.call_envelope_uuid ~call_ordinal:owner.call_ordinal
    ~call_id:owner.call_id in
  Ok {ticket; evidence; observation}

let bind_parent t (parent : Runtime_claude_code.native_agent_parent_witness) =
  let ( let* ) = Result.bind in
  let* ticket, evidence = bind_owner t ~invocation:parent.invocation
    ~call_envelope_uuid:parent.call_envelope_uuid ~call_ordinal:parent.call_ordinal
    ~call_id:parent.call_id in
  Ok {ticket; evidence; parent}

let bind_child t (content : Runtime_claude_code.complete_child_content) =
  let ( let* ) = Result.bind in
  let* () = check_invocation t content.invocation in
  let* parent = match content.parent_occurrence with
    | None -> Error Unknown_parent
    | Some parent ->
        if String.equal content.parent_tool_use_id parent.call_id
           && same_ticket content.invocation parent.invocation
        then Ok parent
        else Error Conflicting_parent_provenance in
  let* parent_input = bind_parent t parent in
  Ok {parent_input; content}

let observe_child t content =
  match bind_child t content with
  | Ok bound -> Child_bound bound
  | Error reason -> Child_rejected {content; reason}

let rejection_to_string = function
  | Missing_ticket -> "no invocation input ticket"
  | Conflicting_invocation -> "conflicting invocation input ticket"
  | Foreign_session -> "native occurrence belongs to another input session"
  | Foreign_invocation -> "native occurrence belongs to another input invocation"
  | Unknown_parent -> "child has no admitted original native parent"
  | Conflicting_parent_provenance -> "child provenance conflicts with its original native parent"
  | Missing_assistant_evidence -> "no input evidence for the native assistant envelope"
  | Unattributed_assistant -> "native assistant envelope has no input attribution"
  | Rejected_assistant _ -> "native assistant input attribution was rejected"
  | Input_not_in_group -> "native assistant attribution does not contain this input"
  | Conflicting_assistant_evidence -> "conflicting native assistant input evidence"
