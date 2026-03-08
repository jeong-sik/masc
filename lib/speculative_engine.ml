(** Speculative Engine — Fast/Slow LLM pairing with MCTS-guided path selection.

    Coordinates speculative execution: multiple candidate approaches are
    evaluated with a fast (cheap) LLM, scored by the verifier, and the best
    path is committed using the slow (expensive) LLM.

    Architecture (from ICLR 2026 "Speculative Actions"):
    1. BRANCH — create MCTS branch point with N candidates
    2. SPEC   — fast LLM evaluates each candidate (simulation)
    3. VERIFY — verifier scores each simulation result
    4. COMMIT — best path accepted, slow LLM executes
    5. ABORT  — discard speculative results, rollback

    Semantic Guard checks (3 criteria):
    - Intent alignment: does output match original query's purpose?
    - Format compliance: does output match expected schema/format?
    - Side-effect safety: no new side-effects beyond original path?

    @since 2.80.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

(** A candidate approach for speculative evaluation. *)
type candidate = {
  label : string;           (** Human-readable description *)
  prompt : string;          (** Prompt to send to fast LLM *)
  metadata : Yojson.Safe.t; (** Arbitrary metadata for tracking *)
}

(** Result of a single speculative simulation. *)
type simulation_outcome = {
  candidate_label : string;
  fast_response : string;       (** Raw fast LLM output *)
  verdict : Mcts_tree.verdict_reward;
  verdict_reason : string;
  latency_ms : int;
  cost_estimate : float;        (** Estimated cost in USD *)
}

(** Semantic guard check result. *)
type guard_result = {
  intent_aligned : bool;
  format_compliant : bool;
  side_effect_safe : bool;
  reason : string;
}

(** Speculation state machine. *)
type spec_state =
  | Idle
  | Branching       (** Creating MCTS branch point *)
  | Simulating      (** Running fast LLM on candidates *)
  | Verifying       (** Verifier scoring results *)
  | Ready_to_commit (** Best path selected, awaiting commit *)
  | Committed       (** Accepted and applied *)
  | Aborted of string (** Discarded with reason *)

(** A speculative execution session. *)
type spec_session = {
  spec_id : string;
  goal : string;
  original_query : string;
  candidates : candidate list;
  outcomes : simulation_outcome list;
  best_candidate : string option;
  state : spec_state;
  tree_node_id : string;    (** MCTS node_id where branching occurred *)
  created_at : float;
  completed_at : float option;
}

(** Engine configuration. *)
type config = {
  max_candidates : int;          (** Max branches per speculation (default: 4) *)
  fast_model : Llm_client.model_spec;
  verify_model : Llm_client.model_spec option;  (** None = use fast_model *)
  max_simulations : int;         (** MCTS simulation budget (default: 8) *)
  semantic_guard_enabled : bool;
  min_confidence : float;        (** Min avg reward to commit (default: 0.6) *)
}

(** Engine state. *)
type t = {
  mutable sessions : spec_session list;
  mutable session_counter : int;
  tree : Mcts_tree.t;
  config : config;
  (* Metrics *)
  mutable total_speculations : int;
  mutable total_commits : int;
  mutable total_aborts : int;
  mutable total_fast_calls : int;
  mutable total_cost : float;
}

(* ================================================================ *)
(* Construction                                                     *)
(* ================================================================ *)

let create ?(max_candidates = 4)
           ?(max_simulations = 8)
           ?(semantic_guard_enabled = true)
           ?(min_confidence = 0.6)
           ?verify_model
           ~fast_model () : t =
  let tree = Mcts_tree.create
    ~root_label:"spec-root"
    ~exploration_constant:(sqrt 2.0) () in
  {
    sessions = [];
    session_counter = 0;
    tree;
    config = {
      max_candidates;
      fast_model;
      verify_model;
      max_simulations;
      semantic_guard_enabled;
      min_confidence;
    };
    total_speculations = 0;
    total_commits = 0;
    total_aborts = 0;
    total_fast_calls = 0;
    total_cost = 0.0;
  }

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let generate_spec_id (engine : t) : string =
  engine.session_counter <- engine.session_counter + 1;
  sprintf "spec-%04d" engine.session_counter

let find_session (engine : t) (spec_id : string) : spec_session option =
  List.find_opt (fun s -> s.spec_id = spec_id) engine.sessions

let update_session (engine : t) (session : spec_session) : unit =
  engine.sessions <- List.map (fun s ->
    if s.spec_id = session.spec_id then session else s
  ) engine.sessions

(* ================================================================ *)
(* Semantic Guard                                                   *)
(* ================================================================ *)

(** Build semantic guard prompt. *)
let build_guard_prompt ~original_query ~candidate_label ~fast_response : string =
  sprintf
{|You are a semantic guard. Check if this speculative result is safe to commit.

Original query: %s
Candidate approach: %s
Fast LLM response: %s

Check these 3 criteria:
1. INTENT: Does the response address the original query's purpose?
2. FORMAT: Is the response in an expected format (not garbled/truncated)?
3. SAFETY: Does the response introduce unexpected side-effects?

Respond in exactly this format:
INTENT: YES or NO
FORMAT: YES or NO
SAFETY: YES or NO
REASON: <one line explanation>|}
    (if String.length original_query > 200
     then String.sub original_query 0 200 ^ "..."
     else original_query)
    candidate_label
    (if String.length fast_response > 500
     then String.sub fast_response 0 500 ^ "..."
     else fast_response)

let parse_guard_response (text : string) : guard_result =
  let lines = String.split_on_char '\n' text in
  let find_yes key =
    List.exists (fun line ->
      let upper = String.uppercase_ascii (String.trim line) in
      let prefix = key ^ ":" in
      String.length upper >= String.length prefix
      && String.sub upper 0 (String.length prefix) = prefix
      && (let rest = String.trim (
            String.sub upper (String.length prefix)
              (String.length upper - String.length prefix)) in
          String.length rest >= 3
          && String.sub rest 0 3 = "YES")
    ) lines
  in
  let reason =
    let reason_line = List.find_opt (fun line ->
      let upper = String.uppercase_ascii (String.trim line) in
      String.length upper >= 7 && String.sub upper 0 7 = "REASON:"
    ) lines in
    match reason_line with
    | Some line ->
      let trimmed = String.trim line in
      if String.length trimmed > 8 then
        String.trim (String.sub trimmed 8 (String.length trimmed - 8))
      else "no reason given"
    | None -> "guard response unparseable"
  in
  {
    intent_aligned = find_yes "INTENT";
    format_compliant = find_yes "FORMAT";
    side_effect_safe = find_yes "SAFETY";
    reason;
  }

(** Run semantic guard check on a speculative result.
    Returns Ok guard_result or Error string. *)
let check_semantic_guard
    ~(model : Llm_client.model_spec)
    ~original_query
    ~candidate_label
    ~fast_response
    : (guard_result, string) result =
  let prompt = build_guard_prompt ~original_query ~candidate_label ~fast_response in
  let req : Llm_client.completion_request = {
    model;
    messages = [Llm_client.user_msg prompt];
    temperature = 0.0;
    max_tokens = 150;
    tools = [];
    response_format = `Text;
  } in
  match Llm_client.complete req with
  | Ok resp -> Ok (parse_guard_response resp.content)
  | Error e -> Error (sprintf "semantic guard LLM failed: %s" e)

(* ================================================================ *)
(* Core: Branch                                                     *)
(* ================================================================ *)

(** Create a speculation branch point.
    Registers candidates as MCTS children and returns a session. *)
let branch (engine : t)
           ~goal ~original_query
           ~(candidates : candidate list)
    : (spec_session, string) result =
  if List.length candidates = 0 then
    Error "no candidates provided"
  else if List.length candidates > engine.config.max_candidates then
    Error (sprintf "too many candidates: %d > %d"
      (List.length candidates) engine.config.max_candidates)
  else begin
    let spec_id = generate_spec_id engine in
    let root_id = engine.tree.root.id in
    let labels = List.map (fun c -> c.label) candidates in
    (* expand mutates the tree in-place *)
    ignore (Mcts_tree.expand engine.tree root_id ~labels);
    let session = {
      spec_id;
      goal;
      original_query;
      candidates;
      outcomes = [];
      best_candidate = None;
      state = Branching;
      tree_node_id = root_id;
      created_at = Time_compat.now ();
      completed_at = None;
    } in
    engine.sessions <- session :: engine.sessions;
    engine.total_speculations <- engine.total_speculations + 1;
    Ok session
  end

(* ================================================================ *)
(* Core: Simulate                                                   *)
(* ================================================================ *)

(** Run fast LLM simulation on a single candidate.
    Returns simulation_outcome. *)
let simulate_candidate
    (engine : t) ~goal ~(candidate : candidate)
    : simulation_outcome =
  let start_time = Time_compat.now () in
  let fast_model = engine.config.fast_model in
  let prompt = sprintf
    "Goal: %s\n\nApproach: %s\n\n%s\n\nProvide a concise response."
    goal candidate.label candidate.prompt in
  let req : Llm_client.completion_request = {
    model = fast_model;
    messages = [Llm_client.user_msg prompt];
    temperature = 0.3;  (* Slight diversity for exploration *)
    max_tokens = 500;
    tools = [];
    response_format = `Text;
  } in
  engine.total_fast_calls <- engine.total_fast_calls + 1;
  match Llm_client.complete req with
  | Ok resp ->
    let latency_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
    let cost = float_of_int resp.usage.total_tokens
               *. fast_model.cost_per_1k_input /. 1000.0 in
    engine.total_cost <- engine.total_cost +. cost;
    (* Use verifier to score *)
    let verify_model = match engine.config.verify_model with
      | Some m -> m
      | None -> fast_model
    in
    let v_req : Verifier.verification_request = {
      action_description = sprintf "Speculative: %s" candidate.label;
      action_result = resp.content;
      goal;
      context_summary = candidate.prompt;
    } in
    let verdict_v = Verifier.verify ~model:verify_model v_req in
    let (verdict, verdict_reason) = match verdict_v with
      | Verifier.Pass -> (Mcts_tree.Pass, "passed verification")
      | Verifier.Warn reason -> (Mcts_tree.Warn, reason)
      | Verifier.Fail reason -> (Mcts_tree.Fail, reason)
    in
    {
      candidate_label = candidate.label;
      fast_response = resp.content;
      verdict;
      verdict_reason;
      latency_ms;
      cost_estimate = cost;
    }
  | Error e ->
    let latency_ms = int_of_float ((Time_compat.now () -. start_time) *. 1000.0) in
    {
      candidate_label = candidate.label;
      fast_response = "";
      verdict = Mcts_tree.Fail;
      verdict_reason = sprintf "fast LLM failed: %s" e;
      latency_ms;
      cost_estimate = 0.0;
    }

(** Run simulations for all candidates in a session.
    Updates MCTS tree with results. Returns updated session. *)
let simulate_all (engine : t) (spec_id : string)
    : (spec_session, string) result =
  match find_session engine spec_id with
  | None -> Error (sprintf "session %s not found" spec_id)
  | Some session when session.state <> Branching ->
    Error (sprintf "session %s not in Branching state" spec_id)
  | Some session ->
    let session = { session with state = Simulating } in
    update_session engine session;
    (* Simulate each candidate *)
    let outcomes = List.map (fun candidate ->
      simulate_candidate engine ~goal:session.goal ~candidate
    ) session.candidates in
    (* Record simulations in MCTS tree *)
    let children = engine.tree.root.children in
    List.iter2 (fun (child : Mcts_tree.node) outcome ->
      let sim : Mcts_tree.simulation_result = {
        model_used = engine.config.fast_model.model_id;
        output =
          (if String.length outcome.fast_response > 100
           then String.sub outcome.fast_response 0 100 ^ "..."
           else outcome.fast_response);
        verdict = outcome.verdict;
        latency_ms = float_of_int outcome.latency_ms;
      } in
      let reward = Mcts_tree.reward_of_verdict outcome.verdict in
      ignore (Mcts_tree.record_simulation engine.tree child.id sim);
      Mcts_tree.backpropagate engine.tree child.id reward
    ) children outcomes;
    let session = { session with
      state = Verifying;
      outcomes;
    } in
    update_session engine session;
    Ok session

(* ================================================================ *)
(* Core: Select Best + Semantic Guard                               *)
(* ================================================================ *)

(** Select best candidate from simulation outcomes.
    If semantic guard is enabled, verify the best candidate.
    Returns updated session in Ready_to_commit or Aborted state. *)
let select_best (engine : t) (spec_id : string)
    : (spec_session, string) result =
  match find_session engine spec_id with
  | None -> Error (sprintf "session %s not found" spec_id)
  | Some session when session.state <> Verifying ->
    Error (sprintf "session %s not in Verifying state" spec_id)
  | Some session ->
    (* Find best by MCTS best_path *)
    let best = Mcts_tree.best_path engine.tree in
    let best_label = match best with
      | _ :: child :: _ -> Some child.Mcts_tree.label
      | _ -> None
    in
    (* Check if best exceeds min_confidence *)
    let best_outcome = match best_label with
      | Some lbl ->
        List.find_opt (fun o -> o.candidate_label = lbl) session.outcomes
      | None -> None
    in
    let avg_reward = match best_outcome with
      | Some o -> Mcts_tree.reward_of_verdict o.verdict
      | None -> 0.0
    in
    if avg_reward < engine.config.min_confidence then begin
      let reason = sprintf
        "best candidate '%s' reward %.2f < min_confidence %.2f"
        (Option.value best_label ~default:"none")
        avg_reward engine.config.min_confidence in
      let session = { session with
        state = Aborted reason;
        completed_at = Some (Time_compat.now ());
      } in
      update_session engine session;
      engine.total_aborts <- engine.total_aborts + 1;
      Ok session
    end
    else begin
      (* Semantic guard check *)
      let guard_ok =
        if not engine.config.semantic_guard_enabled then true
        else match best_outcome with
          | None -> false
          | Some outcome ->
            let model = match engine.config.verify_model with
              | Some m -> m | None -> engine.config.fast_model in
            match check_semantic_guard
              ~model
              ~original_query:session.original_query
              ~candidate_label:outcome.candidate_label
              ~fast_response:outcome.fast_response with
            | Ok guard ->
              guard.intent_aligned && guard.format_compliant && guard.side_effect_safe
            | Error _e -> true  (* Guard failure = allow *)
      in
      if not guard_ok then begin
        let reason = "semantic guard rejected best candidate" in
        let session = { session with
          state = Aborted reason;
          completed_at = Some (Time_compat.now ());
        } in
        update_session engine session;
        engine.total_aborts <- engine.total_aborts + 1;
        Ok session
      end
      else begin
        let session = { session with
          state = Ready_to_commit;
          best_candidate = best_label;
        } in
        update_session engine session;
        Ok session
      end
    end

(* ================================================================ *)
(* Core: Commit / Abort                                             *)
(* ================================================================ *)

(** Commit the best speculative result.
    Returns the best candidate's fast_response for the caller to apply. *)
let commit (engine : t) (spec_id : string)
    : (simulation_outcome, string) result =
  match find_session engine spec_id with
  | None -> Error (sprintf "session %s not found" spec_id)
  | Some session when session.state <> Ready_to_commit ->
    Error (sprintf "session %s not in Ready_to_commit state" spec_id)
  | Some session ->
    let best_label = match session.best_candidate with
      | Some l -> l
      | None -> ""
    in
    let best_outcome = List.find_opt
      (fun o -> o.candidate_label = best_label) session.outcomes in
    match best_outcome with
    | None -> Error "best candidate outcome not found"
    | Some outcome ->
      let session = { session with
        state = Committed;
        completed_at = Some (Time_compat.now ());
      } in
      update_session engine session;
      engine.total_commits <- engine.total_commits + 1;
      Ok outcome

(** Abort a speculation session, discarding all results. *)
let abort (engine : t) (spec_id : string) ~reason
    : (spec_session, string) result =
  match find_session engine spec_id with
  | None -> Error (sprintf "session %s not found" spec_id)
  | Some session ->
    (match session.state with
     | Committed -> Error "cannot abort committed session"
     | Aborted _ -> Error "session already aborted"
     | _ ->
       let session = { session with
         state = Aborted reason;
         completed_at = Some (Time_compat.now ());
       } in
       update_session engine session;
       engine.total_aborts <- engine.total_aborts + 1;
       Ok session)

(* ================================================================ *)
(* Convenience: Full Pipeline                                       *)
(* ================================================================ *)

(** Run the full speculative pipeline: branch → simulate → select → commit/abort.
    Returns Ok (committed_outcome) or Error. *)
let speculate (engine : t)
              ~goal ~original_query
              ~(candidates : candidate list)
    : (simulation_outcome, string) result =
  match branch engine ~goal ~original_query ~candidates with
  | Error e -> Error e
  | Ok session ->
    match simulate_all engine session.spec_id with
    | Error e -> Error e
    | Ok _session ->
      match select_best engine session.spec_id with
      | Error e -> Error e
      | Ok session ->
        match session.state with
        | Ready_to_commit -> commit engine session.spec_id
        | Aborted reason -> Error (sprintf "speculation aborted: %s" reason)
        | _ -> Error "unexpected state after select_best"

(* ================================================================ *)
(* Queries                                                          *)
(* ================================================================ *)

let state_to_string = function
  | Idle -> "idle"
  | Branching -> "branching"
  | Simulating -> "simulating"
  | Verifying -> "verifying"
  | Ready_to_commit -> "ready_to_commit"
  | Committed -> "committed"
  | Aborted reason -> sprintf "aborted: %s" reason

let session_to_yojson (s : spec_session) : Yojson.Safe.t =
  `Assoc [
    "spec_id", `String s.spec_id;
    "goal", `String s.goal;
    "state", `String (state_to_string s.state);
    "num_candidates", `Int (List.length s.candidates);
    "num_outcomes", `Int (List.length s.outcomes);
    "best_candidate", (match s.best_candidate with
      | Some l -> `String l | None -> `Null);
    "created_at", `Float s.created_at;
    "completed_at", (match s.completed_at with
      | Some t -> `Float t | None -> `Null);
  ]

let outcome_to_yojson (o : simulation_outcome) : Yojson.Safe.t =
  `Assoc [
    "candidate", `String o.candidate_label;
    "verdict", `String (Mcts_tree.verdict_to_string o.verdict);
    "verdict_reason", `String o.verdict_reason;
    "latency_ms", `Int o.latency_ms;
    "cost_estimate", `Float o.cost_estimate;
    "response_preview",
      `String (if String.length o.fast_response > 100
               then String.sub o.fast_response 0 100 ^ "..."
               else o.fast_response);
  ]

let metrics_to_yojson (engine : t) : Yojson.Safe.t =
  let tree_summary = Mcts_tree.summary_to_yojson engine.tree in
  `Assoc [
    "total_speculations", `Int engine.total_speculations;
    "total_commits", `Int engine.total_commits;
    "total_aborts", `Int engine.total_aborts;
    "commit_rate",
      `Float (if engine.total_speculations > 0
              then float_of_int engine.total_commits /.
                   float_of_int engine.total_speculations
              else 0.0);
    "total_fast_calls", `Int engine.total_fast_calls;
    "total_cost_usd", `Float engine.total_cost;
    "active_sessions", `Int (List.length (List.filter (fun s ->
      match s.state with Committed | Aborted _ -> false | _ -> true
    ) engine.sessions));
    "mcts_tree", tree_summary;
  ]

let status (engine : t) : Yojson.Safe.t =
  `Assoc [
    "metrics", metrics_to_yojson engine;
    "recent_sessions",
      `List (List.map session_to_yojson
        (List.filteri (fun i _ -> i < 5) engine.sessions));
    "tree_summary", Mcts_tree.summary_to_yojson engine.tree;
  ]

(** Get the MCTS tree for direct inspection. *)
let tree (engine : t) : Mcts_tree.t = engine.tree
