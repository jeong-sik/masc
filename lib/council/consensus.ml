(** Consensus - Multi-agent voting and agreement system *)

(** Decision type for voting *)
type decision =
  | Approve
  | Reject
  | Abstain
[@@deriving show, eq]

(** Individual vote record *)
type vote = {
  agent: string;
  decision: decision;
  reason: string;
  timestamp: float;
}
[@@deriving show, eq]

(** Voting result *)
type voting_result =
  | Unanimous of decision      (** All voters agreed *)
  | Majority of int            (** Majority reached with vote count *)
  | Deadlock                   (** No clear majority *)
  | Escalate                   (** Requires higher authority *)
[@@deriving show, eq]

(** Voting session state *)
type voting_state =
  | Open
  | Closed
  | Cancelled
[@@deriving show, eq]

(** Voting session *)
type session = {
  id: string;
  topic: string;
  initiator: string;
  votes: vote list;
  quorum: int;                 (** Minimum required votes *)
  threshold: float;            (** Majority threshold (0.0-1.0) *)
  state: voting_state;
  created_at: float;
  closed_at: float option;
}

(** Voting error types *)
type error =
  | Session_not_found of string
  | Session_closed of string
  | Already_voted of string
  | Quorum_not_met of { required: int; current: int }
  | Invalid_threshold of float
[@@deriving show, eq]

(** In-memory session store *)
let sessions : (string, session) Hashtbl.t = Hashtbl.create 16

(** Generate unique session ID *)
let generate_id () =
  let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
  Uuidm.to_string uuid

(** Start a new voting session *)
let start_voting ~topic ~initiator ?(quorum = 2) ?(threshold = 0.5) () : (session, error) Result.t =
  if threshold < 0.0 || threshold > 1.0 then
    Error (Invalid_threshold threshold)
  else
    let session = {
      id = generate_id ();
      topic;
      initiator;
      votes = [];
      quorum;
      threshold;
      state = Open;
      created_at = Unix.gettimeofday ();
      closed_at = None;
    } in
    Hashtbl.replace sessions session.id session;
    Ok session

(** Cast a vote in a session *)
let cast_vote ~session_id ~agent ~decision ~reason : (session, error) Result.t =
  match Hashtbl.find_opt sessions session_id with
  | None -> Error (Session_not_found session_id)
  | Some session ->
    if session.state <> Open then
      Error (Session_closed session_id)
    else if List.exists (fun v -> v.agent = agent) session.votes then
      Error (Already_voted agent)
    else
      let vote = {
        agent;
        decision;
        reason;
        timestamp = Unix.gettimeofday ();
      } in
      let updated = { session with votes = vote :: session.votes } in
      Hashtbl.replace sessions session_id updated;
      Ok updated

(** Count votes by decision type *)
let count_by_decision votes decision =
  List.length (List.filter (fun v -> v.decision = decision) votes)

(** Tally votes and compute statistics *)
let tally_votes session : (int * int * int) =
  let approves = count_by_decision session.votes Approve in
  let rejects = count_by_decision session.votes Reject in
  let abstains = count_by_decision session.votes Abstain in
  (approves, rejects, abstains)

(** Check if quorum is met *)
let quorum_met session : bool =
  let total = List.length session.votes in
  total >= session.quorum

(** Get voting result *)
let get_result ~session_id : (voting_result, error) Result.t =
  match Hashtbl.find_opt sessions session_id with
  | None -> Error (Session_not_found session_id)
  | Some session ->
    let votes = session.votes in
    let total = List.length votes in
    
    (* Check quorum *)
    if total < session.quorum then
      Error (Quorum_not_met { required = session.quorum; current = total })
    else
      let approves, rejects, abstains = tally_votes session in
      let voting_count = approves + rejects in  (* Abstains don't count *)
      
      (* Check for unanimous decision *)
      if rejects = 0 && abstains = 0 && approves > 0 then
        Ok (Unanimous Approve)
      else if approves = 0 && abstains = 0 && rejects > 0 then
        Ok (Unanimous Reject)
      else if voting_count = 0 then
        Ok (Unanimous Abstain)
      else
        (* Check for majority *)
        let approve_ratio = Float.of_int approves /. Float.of_int voting_count in
        let reject_ratio = Float.of_int rejects /. Float.of_int voting_count in
        
        if approve_ratio >= session.threshold then
          Ok (Majority approves)
        else if reject_ratio >= session.threshold then
          Ok (Majority rejects)
        else if approve_ratio = reject_ratio then
          Ok Deadlock
        else
          Ok Escalate

(** Close a voting session *)
let close_session ~session_id : (session, error) Result.t =
  match Hashtbl.find_opt sessions session_id with
  | None -> Error (Session_not_found session_id)
  | Some session ->
    let updated = { 
      session with 
      state = Closed;
      closed_at = Some (Unix.gettimeofday ());
    } in
    Hashtbl.replace sessions session_id updated;
    Ok updated

(** Cancel a voting session *)
let cancel_session ~session_id : (session, error) Result.t =
  match Hashtbl.find_opt sessions session_id with
  | None -> Error (Session_not_found session_id)
  | Some session ->
    let updated = { 
      session with 
      state = Cancelled;
      closed_at = Some (Unix.gettimeofday ());
    } in
    Hashtbl.replace sessions session_id updated;
    Ok updated

(** Get session by ID *)
let get_session ~session_id : session option =
  Hashtbl.find_opt sessions session_id

(** List all active sessions *)
let list_active_sessions () : session list =
  Hashtbl.to_seq_values sessions
  |> Seq.filter (fun s -> s.state = Open)
  |> List.of_seq

(** Clear all sessions (for testing) *)
let clear_sessions () =
  Hashtbl.clear sessions

(** Session to JSON *)
let session_to_json session : Yojson.Safe.t =
  let approves, rejects, abstains = tally_votes session in
  `Assoc [
    ("id", `String session.id);
    ("topic", `String session.topic);
    ("initiator", `String session.initiator);
    ("quorum", `Int session.quorum);
    ("threshold", `Float session.threshold);
    ("state", voting_state_to_yojson session.state);
    ("vote_count", `Int (List.length session.votes));
    ("approves", `Int approves);
    ("rejects", `Int rejects);
    ("abstains", `Int abstains);
    ("quorum_met", `Bool (quorum_met session));
    ("created_at", `Float session.created_at);
    ("closed_at", match session.closed_at with
      | Some t -> `Float t
      | None -> `Null);
  ]

(** Result to JSON *)
let voting_result_to_json = function
  | Unanimous decision -> 
    `Assoc [("type", `String "unanimous"); ("decision", decision_to_yojson decision)]
  | Majority count ->
    `Assoc [("type", `String "majority"); ("count", `Int count)]
  | Deadlock ->
    `Assoc [("type", `String "deadlock")]
  | Escalate ->
    `Assoc [("type", `String "escalate")]
