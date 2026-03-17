(** GAME-VIEW decision state store.

    Stores decision lifecycle records used by:
    - decision.create / decision.finalize
    - experiment.start / trpg.action.submit precondition checks
*)

open Yojson.Safe.Util

type decision = {
  decision_id: string;
  session_id: string;
  issue: string;
  options: string list;
  criteria: string list;
  weights: Yojson.Safe.t option;
  created_at: float;
  finalized_at: float option;
  selected_option: string option;
  rationale: string option;
  confidence: float option;
  verifier: string option;
  risk_ack: string option;
}

type client_session = {
  session_id: string;
  trace_id: string option;
  agent_name: string;
  created_at: float;
  last_seen: float;
}

type client_subscription = {
  subscription_id: string;
  session_id: string;
  topics: string list;
  accepted_topics: string list;
  rejected_topics: string list;
  created_at: float;
}

type client_input_status =
  | Pending
  | Approved
  | Rejected

type client_input = {
  input_id: string;
  session_id: string;
  input: string;
  status: client_input_status;
  submitted_by: string;
  submitted_at: float;
  handled_by: string option;
  handled_at: float option;
  reject_reason: string option;
}

let decisions_path config =
  Filename.concat (Room.masc_dir config) "game_view_decisions.json"

let client_sessions_path config =
  Filename.concat (Room.masc_dir config) "game_view_clients.json"

let client_subscriptions_path config =
  Filename.concat (Room.masc_dir config) "game_view_subscriptions.json"

let client_inputs_path config =
  Filename.concat (Room.masc_dir config) "game_view_inputs.json"

let decision_to_json (d : decision) =
  `Assoc [
    ("decision_id", `String d.decision_id);
    ("session_id", `String d.session_id);
    ("issue", `String d.issue);
    ("options", `List (List.map (fun s -> `String s) d.options));
    ("criteria", `List (List.map (fun s -> `String s) d.criteria));
    ("weights", match d.weights with Some w -> w | None -> `Null);
    ("created_at", `Float d.created_at);
    ("finalized_at", match d.finalized_at with Some ts -> `Float ts | None -> `Null);
    ("selected_option", match d.selected_option with Some s -> `String s | None -> `Null);
    ("rationale", match d.rationale with Some s -> `String s | None -> `Null);
    ("confidence", match d.confidence with Some c -> `Float c | None -> `Null);
    ("verifier", match d.verifier with Some s -> `String s | None -> `Null);
    ("risk_ack", match d.risk_ack with Some s -> `String s | None -> `Null);
  ]

let client_session_to_json (s : client_session) =
  `Assoc [
    ("session_id", `String s.session_id);
    ("trace_id", Option.fold ~none:`Null ~some:(fun v -> `String v) s.trace_id);
    ("agent_name", `String s.agent_name);
    ("created_at", `Float s.created_at);
    ("last_seen", `Float s.last_seen);
  ]

let client_session_of_json json =
  let session_id = Safe_ops.json_string "session_id" json in
  if session_id = "" then
    None
  else
    Some {
      session_id;
      trace_id = Safe_ops.json_string_opt "trace_id" json;
      agent_name = Safe_ops.json_string ~default:"unknown" "agent_name" json;
      created_at = Safe_ops.json_float ~default:(Time_compat.now ()) "created_at" json;
      last_seen = Safe_ops.json_float ~default:(Time_compat.now ()) "last_seen" json;
    }

let client_subscription_to_json (s : client_subscription) =
  `Assoc [
    ("subscription_id", `String s.subscription_id);
    ("session_id", `String s.session_id);
    ("topics", `List (List.map (fun v -> `String v) s.topics));
    ("accepted_topics", `List (List.map (fun v -> `String v) s.accepted_topics));
    ("rejected_topics", `List (List.map (fun v -> `String v) s.rejected_topics));
    ("created_at", `Float s.created_at);
  ]

let client_input_status_to_string = function
  | Pending -> "pending"
  | Approved -> "approved"
  | Rejected -> "rejected"

let client_input_status_of_string = function
  | "pending" -> Some Pending
  | "approved" -> Some Approved
  | "rejected" -> Some Rejected
  | _ -> None

let client_input_to_json (i : client_input) =
  `Assoc [
    ("input_id", `String i.input_id);
    ("session_id", `String i.session_id);
    ("input", `String i.input);
    ("status", `String (client_input_status_to_string i.status));
    ("submitted_by", `String i.submitted_by);
    ("submitted_at", `Float i.submitted_at);
    ("handled_by", Option.fold ~none:`Null ~some:(fun v -> `String v) i.handled_by);
    ("handled_at", Option.fold ~none:`Null ~some:(fun v -> `Float v) i.handled_at);
    ( "reject_reason",
      Option.fold ~none:`Null ~some:(fun v -> `String v) i.reject_reason );
  ]

let client_subscription_of_json json =
  let subscription_id = Safe_ops.json_string "subscription_id" json in
  let session_id = Safe_ops.json_string "session_id" json in
  if subscription_id = "" || session_id = "" then
    None
  else
    Some {
      subscription_id;
      session_id;
      topics = Safe_ops.json_string_list "topics" json;
      accepted_topics = Safe_ops.json_string_list "accepted_topics" json;
      rejected_topics = Safe_ops.json_string_list "rejected_topics" json;
      created_at = Safe_ops.json_float ~default:(Time_compat.now ()) "created_at" json;
    }

let client_input_of_json json =
  let input_id = Safe_ops.json_string "input_id" json in
  let session_id = Safe_ops.json_string "session_id" json in
  let input = Safe_ops.json_string "input" json in
  let status_opt =
    Safe_ops.json_string ~default:"pending" "status" json
    |> client_input_status_of_string
  in
  if input_id = "" || session_id = "" || input = "" then
    None
  else
    match status_opt with
    | None -> None
    | Some status ->
        Some {
          input_id;
          session_id;
          input;
          status;
          submitted_by = Safe_ops.json_string ~default:"unknown" "submitted_by" json;
          submitted_at = Safe_ops.json_float ~default:(Time_compat.now ()) "submitted_at" json;
          handled_by = Safe_ops.json_string_opt "handled_by" json;
          handled_at = Safe_ops.json_float_opt "handled_at" json;
          reject_reason = Safe_ops.json_string_opt "reject_reason" json;
        }

let decision_of_json json : decision option =
  let decision_id = Safe_ops.json_string "decision_id" json in
  let session_id = Safe_ops.json_string "session_id" json in
  if decision_id = "" || session_id = "" then
    None
  else
    let weights =
      match json |> member "weights" with
      | (`Assoc _ as w) -> Some w
      | _ -> None
    in
    Some {
      decision_id;
      session_id;
      issue = Safe_ops.json_string "issue" json;
      options = Safe_ops.json_string_list "options" json;
      criteria = Safe_ops.json_string_list "criteria" json;
      weights;
      created_at = Safe_ops.json_float ~default:(Time_compat.now ()) "created_at" json;
      finalized_at = Safe_ops.json_float_opt "finalized_at" json;
      selected_option = Safe_ops.json_string_opt "selected_option" json;
      rationale = Safe_ops.json_string_opt "rationale" json;
      confidence = Safe_ops.json_float_opt "confidence" json;
      verifier = Safe_ops.json_string_opt "verifier" json;
      risk_ack = Safe_ops.json_string_opt "risk_ack" json;
    }

let load_decisions (config : Room.config) : decision list =
  let path = decisions_path config in
  match Room_utils.read_json_opt config path with
  | None -> []
  | Some json ->
      (match json |> member "decisions" with
       | `List items -> List.filter_map decision_of_json items
       | _ -> [])

let save_decisions (config : Room.config) (decisions : decision list) =
  let path = decisions_path config in
  Room_utils.write_json config path
    (`Assoc [("decisions", `List (List.map decision_to_json decisions))])

let load_client_sessions (config : Room.config) : client_session list =
  let path = client_sessions_path config in
  match Room_utils.read_json_opt config path with
  | None -> []
  | Some json ->
      (match json |> member "sessions" with
       | `List items -> List.filter_map client_session_of_json items
       | _ -> [])

let save_client_sessions (config : Room.config) (sessions : client_session list) =
  let path = client_sessions_path config in
  Room_utils.write_json config path
    (`Assoc [("sessions", `List (List.map client_session_to_json sessions))])

let load_client_subscriptions (config : Room.config) : client_subscription list =
  let path = client_subscriptions_path config in
  match Room_utils.read_json_opt config path with
  | None -> []
  | Some json ->
      (match json |> member "subscriptions" with
       | `List items -> List.filter_map client_subscription_of_json items
       | _ -> [])

let save_client_subscriptions (config : Room.config)
    (subs : client_subscription list) =
  let path = client_subscriptions_path config in
  Room_utils.write_json config path
    (`Assoc [("subscriptions", `List (List.map client_subscription_to_json subs))])

let load_client_inputs (config : Room.config) : client_input list =
  let path = client_inputs_path config in
  match Room_utils.read_json_opt config path with
  | None -> []
  | Some json ->
      (match json |> member "inputs" with
       | `List items -> List.filter_map client_input_of_json items
       | _ -> [])

let save_client_inputs (config : Room.config) (inputs : client_input list) =
  let path = client_inputs_path config in
  Room_utils.write_json config path
    (`Assoc [("inputs", `List (List.map client_input_to_json inputs))])

let rec replace_client_session
    (acc : client_session list)
    (target : client_session)
    (items : client_session list) : client_session list =
  match items with
  | [] -> List.rev (target :: acc)
  | s :: rest ->
      if s.session_id = target.session_id then
        List.rev_append acc (target :: rest)
      else
        replace_client_session (s :: acc) target rest

let get_client_session (config : Room.config) ~session_id : client_session option =
  load_client_sessions config
  |> List.find_opt (fun (s : client_session) -> s.session_id = session_id)

let open_client_session (config : Room.config) ~session_id ~trace_id ~agent_name
    : client_session =
  let now = Time_compat.now () in
  let all : client_session list = load_client_sessions config in
  let updated =
    match List.find_opt (fun (s : client_session) -> s.session_id = session_id) all with
    | Some existing ->
        {
          existing with
          trace_id =
            (match trace_id with
             | Some _ -> trace_id
             | None -> existing.trace_id);
          agent_name =
            (if String.trim agent_name = "" then existing.agent_name else agent_name);
          last_seen = now;
        }
    | None ->
        {
          session_id;
          trace_id;
          agent_name = if String.trim agent_name = "" then "unknown" else agent_name;
          created_at = now;
          last_seen = now;
        }
  in
  save_client_sessions config (replace_client_session [] updated all);
  updated

let create_client_subscription
    (config : Room.config)
    ~session_id ~topics ~accepted_topics ~rejected_topics
    : client_subscription =
  let now = Time_compat.now () in
  let subscription_id =
    Printf.sprintf "gvsub-%Ld" (Int64.of_float (now *. 1_000_000.0))
  in
  let sub = {
    subscription_id;
    session_id;
    topics;
    accepted_topics;
    rejected_topics;
    created_at = now;
  } in
  let all = load_client_subscriptions config in
  save_client_subscriptions config (sub :: all);
  sub

let get_client_subscriptions (config : Room.config) ~session_id : client_subscription list =
  load_client_subscriptions config
  |> List.filter (fun (s : client_subscription) -> s.session_id = session_id)

let get_client_input (config : Room.config) ~session_id ~input_id : client_input option =
  load_client_inputs config
  |> List.find_opt
       (fun (i : client_input) ->
         i.session_id = session_id && i.input_id = input_id)

let get_client_inputs (config : Room.config) ~session_id : client_input list =
  load_client_inputs config
  |> List.filter (fun (i : client_input) -> i.session_id = session_id)

let create_client_input (config : Room.config) ~session_id ~input ~submitted_by
    : client_input =
  let now = Time_compat.now () in
  let input_id = Printf.sprintf "gvinput-%Ld" (Int64.of_float (now *. 1_000_000.0)) in
  let item = {
    input_id;
    session_id;
    input;
    status = Pending;
    submitted_by = if String.trim submitted_by = "" then "unknown" else submitted_by;
    submitted_at = now;
    handled_by = None;
    handled_at = None;
    reject_reason = None;
  } in
  let all = load_client_inputs config in
  save_client_inputs config (item :: all);
  item

let transition_client_input (config : Room.config) ~session_id ~input_id
    ~status ~handled_by ~reject_reason
    : (client_input, string) result =
  let all : client_input list = load_client_inputs config in
  let now = Time_compat.now () in
  let rec loop acc = function
    | [] ->
        Error
          (Printf.sprintf
             "input not found: %s (session: %s)"
             input_id
             session_id)
    | (i : client_input) :: rest ->
        if i.session_id = session_id && i.input_id = input_id then
          if i.status <> Pending then
            Error
              (Printf.sprintf
                 "input already handled: %s (status=%s)"
                 input_id
                 (client_input_status_to_string i.status))
          else
            let updated = {
              i with
              status;
              handled_by = Some handled_by;
              handled_at = Some now;
              reject_reason;
            } in
            let merged = List.rev_append acc (updated :: rest) in
            save_client_inputs config merged;
            Ok updated
        else
          loop (i :: acc) rest
  in
  loop [] all

let create_decision (config : Room.config)
    ~session_id ~issue ~options ~criteria ~weights
    : decision =
  let now = Time_compat.now () in
  let decision_id =
    Printf.sprintf "decision-%Ld" (Int64.of_float (now *. 1_000_000.0))
  in
  let decision = {
    decision_id;
    session_id;
    issue;
    options;
    criteria;
    weights;
    created_at = now;
    finalized_at = None;
    selected_option = None;
    rationale = None;
    confidence = None;
    verifier = None;
    risk_ack = None;
  } in
  let decisions = load_decisions config in
  save_decisions config (decision :: decisions);
  decision

let is_finalized (d : decision) = d.finalized_at <> None

let finalize_decision (config : Room.config)
    ~session_id ~decision_id ~selected_option ~rationale
    ~confidence ~verifier ~risk_ack
    : (decision, string) result =
  let decisions : decision list = load_decisions config in
  let rec loop acc = function
    | [] ->
        Error (Printf.sprintf "decision not found: %s (session: %s)" decision_id session_id)
    | (d : decision) :: rest ->
        if d.session_id = session_id && d.decision_id = decision_id then begin
          if is_finalized d then
            Error (Printf.sprintf
                     "decision %s is already finalized (at %s)"
                     decision_id
                     (match d.finalized_at with Some ts -> Printf.sprintf "%.0f" ts | None -> "unknown"))
          else if not (List.mem selected_option d.options) then
            Error (Printf.sprintf
                     "selected_option '%s' not in decision options"
                     selected_option)
          else
            let finalized = {
              d with
              finalized_at = Some (Time_compat.now ());
              selected_option = Some selected_option;
              rationale = Some rationale;
              confidence;
              verifier = Some verifier;
              risk_ack;
            } in
            let merged = List.rev_append acc (finalized :: rest) in
            save_decisions config merged;
            Ok finalized
        end else
          loop (d :: acc) rest
  in
  loop [] decisions

let find_decision (decisions : decision list) ~session_id ~decision_id =
  List.find_opt
    (fun (d : decision) -> d.session_id = session_id && d.decision_id = decision_id)
    decisions

let latest_finalized_decision (config : Room.config) ~session_id : decision option =
  let score (d : decision) =
    match d.finalized_at with
    | Some ts -> ts
    | None -> d.created_at
  in
  load_decisions config
  |> List.filter (fun (d : decision) -> d.session_id = session_id && is_finalized d)
  |> List.sort (fun a b -> Float.compare (score b) (score a))
  |> function
     | head :: _ -> Some head
     | [] -> None

let finalized_decision_for_session ?decision_id (config : Room.config) ~session_id
    : (decision, string) result =
  let decisions : decision list = load_decisions config in
  match decision_id with
  | Some did when String.trim did <> "" ->
      (match find_decision decisions ~session_id ~decision_id:did with
       | None ->
           Error (Printf.sprintf "decision not found: %s (session: %s)" did session_id)
       | Some d when not (is_finalized d) ->
           Error (Printf.sprintf "decision not finalized yet: %s" did)
       | Some d -> Ok d)
  | _ ->
      (match latest_finalized_decision config ~session_id with
       | Some d -> Ok d
       | None ->
           Error (Printf.sprintf
                    "no finalized decision for session: %s (decision.finalize required)"
                    session_id))
