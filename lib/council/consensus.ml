(** Consensus - Multi-agent voting and agreement system *)

(** Decision type for voting *)
type decision =
  | Approve
  | Reject
  | Abstain
[@@deriving show, eq]

let decision_to_yojson = function
  | Approve -> `String "approve"
  | Reject -> `String "reject"
  | Abstain -> `String "abstain"

(** Individual vote record *)
type vote = {
  agent: string;
  decision: decision;
  reason: string;
  timestamp: float;
  archetype: string option;  (** MAGI archetype for weighted voting *)
  weight: float;             (** Vote weight (default 1.0) *)
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

type context_ref = {
  board_post_id: string option;
  task_id: string option;
  operation_id: string option;
  team_session_id: string option;
}

let voting_state_to_yojson = function
  | Open -> `String "open"
  | Closed -> `String "closed"
  | Cancelled -> `String "cancelled"

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
  context: context_ref;
}

(** Voting error types *)
type error =
  | Session_not_found of string
  | Session_closed of string
  | Already_voted of string
  | Quorum_not_met of { required: int; current: int }
  | Invalid_threshold of float
  | Persistence_failed of string
[@@deriving show, eq]

(** In-memory session store *)
let sessions : (string, session) Hashtbl.t = Hashtbl.create 16

(** Module-level mutex protecting [sessions] Hashtbl.
    All reads/writes to [sessions] must go through this lock. *)
let sessions_mutex : Eio.Mutex.t = Eio.Mutex.create ()

let with_sessions_lock f =
  Eio_guard.with_mutex sessions_mutex f

let with_sessions_ro f =
  Eio_guard.with_mutex_ro sessions_mutex f

(** {1 File-based Persistence} *)

(** Optional base_path for file storage — set via [init] *)
let _base_path : string option ref = ref None

let read_file_safe path =
  try Ok (Fs_compat.load_file path)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let list_dir_safe dir =
  try Ok (Array.to_list (Sys.readdir dir))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

let consensus_dir base =
  Filename.concat (Filename.concat base ".masc") "consensus"

let session_path base session_id =
  Filename.concat (consensus_dir base) (session_id ^ ".json")

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then
      ensure_dir parent;
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(** Write JSON to file atomically (temp file + rename) *)
let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let base_name = Filename.basename path in
  let tmp_path = Filename.concat dir (Printf.sprintf ".%s.tmp.%d" base_name (Unix.getpid ())) in
  match
    Fs_compat.save_file tmp_path content;
    Sys.rename tmp_path path
  with
  | () -> ()
  | exception (Eio.Cancel.Cancelled _ as e) ->
      (try Sys.remove tmp_path with Sys_error _ -> ());
      raise e
  | exception exn ->
      (try Sys.remove tmp_path with Sys_error _ -> ());
      raise exn

(** {1 JSON Serialization (full, for persistence)} *)

let decision_of_yojson = function
  | `String "approve" -> Ok Approve
  | `String "reject" -> Ok Reject
  | `String "abstain" -> Ok Abstain
  | j -> Error (Printf.sprintf "Unknown decision: %s" (Yojson.Safe.to_string j))

let voting_state_of_yojson = function
  | `String "open" -> Ok Open
  | `String "closed" -> Ok Closed
  | `String "cancelled" -> Ok Cancelled
  | j -> Error (Printf.sprintf "Unknown voting_state: %s" (Yojson.Safe.to_string j))

let empty_context_ref =
  {
    board_post_id = None;
    task_id = None;
    operation_id = None;
    team_session_id = None;
  }

let context_ref_to_yojson (ctx : context_ref) =
  let fields =
    [
      ("board_post_id", ctx.board_post_id);
      ("task_id", ctx.task_id);
      ("operation_id", ctx.operation_id);
      ("team_session_id", ctx.team_session_id);
    ]
    |> List.filter_map (fun (key, value) ->
           match value with
           | Some text when String.trim text <> "" -> Some (key, `String (String.trim text))
           | _ -> None)
  in
  `Assoc fields

let context_ref_of_yojson json =
  let open Yojson.Safe.Util in
  let get_opt key =
    match json |> member key with
    | `String value ->
        let trimmed = String.trim value in
        if trimmed = "" then None else Some trimmed
    | _ -> None
  in
  {
    board_post_id = get_opt "board_post_id";
    task_id = get_opt "task_id";
    operation_id = get_opt "operation_id";
    team_session_id = get_opt "team_session_id";
  }

let vote_to_yojson (v : vote) : Yojson.Safe.t =
  let base = [
    ("agent", `String v.agent);
    ("decision", decision_to_yojson v.decision);
    ("reason", `String v.reason);
    ("timestamp", `Float v.timestamp);
    ("weight", `Float v.weight);
  ] in
  let with_archetype = match v.archetype with
    | None -> base
    | Some a -> ("archetype", `String a) :: base
  in
  `Assoc with_archetype

let vote_of_yojson (json : Yojson.Safe.t) : (vote, string) result =
  let open Yojson.Safe.Util in
  try
    let agent = json |> member "agent" |> to_string in
    let decision_json = json |> member "decision" in
    match decision_of_yojson decision_json with
    | Error e -> Error e
    | Ok decision ->
        let reason = json |> member "reason" |> to_string in
        let timestamp = json |> member "timestamp" |> to_float in
        let weight = (try json |> member "weight" |> to_float with Yojson.Safe.Util.Type_error _ -> 1.0) in
        let archetype = match json |> member "archetype" with
          | `String s -> Some s
          | _ -> None
        in
        Ok { agent; decision; reason; timestamp; archetype; weight }
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse vote: %s" (Printexc.to_string e))

let full_session_to_yojson (s : session) : Yojson.Safe.t =
  let base =
    [
      ("id", `String s.id);
      ("topic", `String s.topic);
      ("initiator", `String s.initiator);
      ("votes", `List (List.map vote_to_yojson s.votes));
      ("quorum", `Int s.quorum);
      ("threshold", `Float s.threshold);
      ("state", voting_state_to_yojson s.state);
      ("created_at", `Float s.created_at);
      ("closed_at", Json_util.float_opt_to_json s.closed_at);
    ]
  in
  let with_context =
    match context_ref_to_yojson s.context with
    | `Assoc [] -> base
    | json -> ("context", json) :: base
  in
  `Assoc with_context

let full_session_of_yojson (json : Yojson.Safe.t) : (session, string) result =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let topic = json |> member "topic" |> to_string in
    let initiator = json |> member "initiator" |> to_string in
    let quorum = json |> member "quorum" |> to_int in
    let threshold = json |> member "threshold" |> to_float in
    let state_json = json |> member "state" in
    match voting_state_of_yojson state_json with
    | Error e -> Error e
    | Ok state ->
        let created_at = json |> member "created_at" |> to_float in
        let closed_at = match json |> member "closed_at" with
          | `Float t -> Some t
          | _ -> None
        in
        let votes_json = json |> member "votes" |> to_list in
        let rec collect_votes acc = function
          | [] -> Ok (List.rev acc)
          | hd :: rest ->
              match vote_of_yojson hd with
              | Error e -> Error e
              | Ok v -> collect_votes (v :: acc) rest
        in
        (match collect_votes [] votes_json with
         | Error e -> Error e
         | Ok votes ->
             let context =
               match json |> member "context" with
               | `Assoc _ as ctx -> context_ref_of_yojson ctx
               | _ -> empty_context_ref
             in
             Ok { id; topic; initiator; votes; quorum; threshold; state; created_at; closed_at; context })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "Failed to parse session: %s" (Printexc.to_string e))

(** Persist session before mutating in-memory state to avoid state tear. *)
let persist_session (s : session) : (unit, error) result =
  match !_base_path with
  | None -> Ok ()
  | Some base ->
    let dir = consensus_dir base in
    try
      ensure_dir dir;
      let path = session_path base s.id in
      write_json path (full_session_to_yojson s);
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (Persistence_failed (Printexc.to_string e))

let commit_session (s : session) : (session, error) result =
  match persist_session s with
  | Error _ as err -> err
  | Ok () ->
    with_sessions_lock (fun () ->
      Hashtbl.replace sessions s.id s);
    Ok s

(** Load all sessions from disk into memory *)
let load_sessions base =
  let dir = consensus_dir base in
  if Sys.file_exists dir then
    match list_dir_safe dir with
    | Error e -> Log.Council.debug "consensus dir listing failed: %s" e
    | Ok files ->
        List.iter (fun filename ->
          if Filename.check_suffix filename ".json" then
            let path = Filename.concat dir filename in
            match read_file_safe path with
            | Error e -> Log.Council.debug "consensus file read failed %s: %s" filename e
            | Ok content ->
                (try
                   let json = Yojson.Safe.from_string content in
                   match full_session_of_yojson json with
                   | Ok session ->
                     with_sessions_lock (fun () ->
                       Hashtbl.replace sessions session.id session)
                   | Error e -> Log.Council.debug "consensus session parse failed %s: %s" filename e
                 with Yojson.Json_error msg -> Log.Council.debug "consensus JSON error %s: %s" filename msg
                    | Failure msg -> Log.Council.debug "consensus failure %s: %s" filename msg)
        ) files

(** Initialize consensus with file persistence *)
let init ~base_path =
  _base_path := Some base_path;
  load_sessions base_path

(** {1 Cleanup} *)

(** Remove closed/cancelled sessions older than [max_age_s] seconds.
    Returns the count of removed sessions. *)
let cleanup_closed ?(max_age_s = 3600.0) () =
  let now = Time_compat.now () in
  let stale = with_sessions_ro (fun () ->
    Hashtbl.fold (fun id session acc ->
      match session.state with
      | Closed | Cancelled ->
        (match session.closed_at with
         | Some t when now -. t > max_age_s -> id :: acc
         | _ -> acc)
      | Open -> acc
    ) sessions []) in
  with_sessions_lock (fun () ->
    List.iter (Hashtbl.remove sessions) stale);
  List.length stale

(** Generate unique session ID *)
let consensus_rng = Random.State.make_self_init ()
let rng_mutex : Eio.Mutex.t = Eio.Mutex.create ()
let generate_id () =
  let uuid = Eio_guard.with_mutex rng_mutex (fun () ->
    Uuidm.v4_gen consensus_rng ()) in
  Uuidm.to_string uuid

(** Start a new voting session *)
let start_voting ~topic ~initiator ?(quorum = 2) ?(threshold = 0.5)
    ?(context = empty_context_ref) () : (session, error) Result.t =
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
      created_at = Time_compat.now ();
      closed_at = None;
      context;
    } in
    commit_session session

(** Cast a vote in a session.
    Read-validate-persist-replace within a single write lock to prevent TOCTOU. *)
let cast_vote ~session_id ~agent ~decision ~reason ?(archetype=None) ?(weight=1.0) () : (session, error) Result.t =
  with_sessions_lock (fun () ->
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
          timestamp = Time_compat.now ();
          archetype;
          weight;
        } in
        let updated = { session with votes = vote :: session.votes } in
        match persist_session updated with
        | Error _ as err -> err
        | Ok () ->
          Hashtbl.replace sessions updated.id updated;
          Ok updated)

(** Count votes by decision type *)
let count_by_decision votes decision =
  List.length (List.filter (fun v -> v.decision = decision) votes)

(** Sum weighted votes by decision type *)
let sum_weighted_by_decision votes decision =
  List.fold_left (fun acc v -> 
    if v.decision = decision then acc +. v.weight else acc
  ) 0.0 votes

(** Tally votes and compute statistics *)
let tally_votes session : (int * int * int) =
  let approves = count_by_decision session.votes Approve in
  let rejects = count_by_decision session.votes Reject in
  let abstains = count_by_decision session.votes Abstain in
  (approves, rejects, abstains)

(** Tally weighted votes *)
let tally_votes_weighted session : (float * float * float) =
  let approves = sum_weighted_by_decision session.votes Approve in
  let rejects = sum_weighted_by_decision session.votes Reject in
  let abstains = sum_weighted_by_decision session.votes Abstain in
  (approves, rejects, abstains)

(** Check if quorum is met *)
let quorum_met session : bool =
  let total = List.length session.votes in
  total >= session.quorum

(** Get voting result *)
let get_result ~session_id : (voting_result, error) Result.t =
  let session_opt = with_sessions_ro (fun () ->
    Hashtbl.find_opt sessions session_id) in
  match session_opt with
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

(** Close a voting session.
    Read-validate-persist-replace within a single write lock to prevent TOCTOU. *)
let close_session ~session_id : (session, error) Result.t =
  with_sessions_lock (fun () ->
    match Hashtbl.find_opt sessions session_id with
    | None -> Error (Session_not_found session_id)
    | Some session ->
      let updated = {
        session with
        state = Closed;
        closed_at = Some (Time_compat.now ());
      } in
      match persist_session updated with
      | Error _ as err -> err
      | Ok () ->
        Hashtbl.replace sessions updated.id updated;
        Ok updated)

(** Cancel a voting session.
    Read-validate-persist-replace within a single write lock to prevent TOCTOU. *)
let cancel_session ~session_id : (session, error) Result.t =
  with_sessions_lock (fun () ->
    match Hashtbl.find_opt sessions session_id with
    | None -> Error (Session_not_found session_id)
    | Some session ->
      let updated = {
        session with
        state = Cancelled;
        closed_at = Some (Time_compat.now ());
      } in
      match persist_session updated with
      | Error _ as err -> err
      | Ok () ->
        Hashtbl.replace sessions updated.id updated;
        Ok updated)

(** Get session by ID *)
let get_session ~session_id : session option =
  with_sessions_ro (fun () ->
    Hashtbl.find_opt sessions session_id)

(** List all active sessions *)
let list_active_sessions () : session list =
  with_sessions_ro (fun () ->
    Hashtbl.to_seq_values sessions
    |> Seq.filter (fun s -> s.state = Open)
    |> List.of_seq)

let list_all_sessions () : session list =
  with_sessions_ro (fun () ->
    Hashtbl.to_seq_values sessions |> List.of_seq)

(** Clear all sessions (for testing) *)
let clear_sessions () =
  with_sessions_lock (fun () ->
    Hashtbl.clear sessions)

(** Session to JSON *)
let session_to_json session : Yojson.Safe.t =
  let approves, rejects, abstains = tally_votes session in
  let base =
    [
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
  in
  let with_context =
    match context_ref_to_yojson session.context with
    | `Assoc [] -> base
    | json -> ("context", json) :: base
  in
  `Assoc with_context

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

(** Human-friendly result string *)
let voting_result_to_string = function
  | Unanimous Approve -> "✅ Unanimous: Approved"
  | Unanimous Reject -> "❌ Unanimous: Rejected"
  | Unanimous Abstain -> "⚪ Unanimous: Abstained"
  | Majority count -> Printf.sprintf "📊 Majority: %d votes" count
  | Deadlock -> "🔒 Deadlock: No consensus reached"
  | Escalate -> "⬆️ Escalate: Requires higher authority"
