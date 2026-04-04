open Types

module U = Yojson.Safe.Util

type evidence_outcome =
  | Satisfied
  | Missing
  | Failed
  | Unsupported

type evidence_check = {
  evidence : string;
  outcome : evidence_outcome;
  detail : string;
}

type gate_status =
  | Ready
  | Blocked
  | Inconclusive

type gate_evaluation = {
  status : gate_status;
  checks : evidence_check list;
  reasons : string list;
}

type task_snapshot = {
  strict : bool;
  completion_contract : string list;
  unmet_completion_contract : string list;
  done_gate : gate_evaluation;
  inspect_gate : gate_evaluation option;
  verify_gate : gate_evaluation option;
}

let string_list_to_json values =
  `List (List.map (fun value -> `String value) values)

let outcome_to_string = function
  | Satisfied -> "satisfied"
  | Missing -> "missing"
  | Failed -> "failed"
  | Unsupported -> "unsupported"

let gate_status_to_string = function
  | Ready -> "ready"
  | Blocked -> "blocked"
  | Inconclusive -> "inconclusive"

let evidence_check_to_yojson (check : evidence_check) =
  `Assoc
    [
      ("evidence", `String check.evidence);
      ("outcome", `String (outcome_to_string check.outcome));
      ("detail", `String check.detail);
    ]

let gate_evaluation_to_yojson (gate : gate_evaluation) =
  `Assoc
    [
      ("status", `String (gate_status_to_string gate.status));
      ("checks", `List (List.map evidence_check_to_yojson gate.checks));
      ("reasons", string_list_to_json gate.reasons);
    ]

let task_snapshot_to_yojson (snapshot : task_snapshot) =
  `Assoc
    [
      ("strict", `Bool snapshot.strict);
      ("completion_contract", string_list_to_json snapshot.completion_contract);
      ( "unmet_completion_contract",
        string_list_to_json snapshot.unmet_completion_contract );
      ("done", gate_evaluation_to_yojson snapshot.done_gate);
      ( "inspect_to_implement",
        match snapshot.inspect_gate with
        | Some gate -> gate_evaluation_to_yojson gate
        | None -> `Null );
      ( "verify_to_review",
        match snapshot.verify_gate with
        | Some gate -> gate_evaluation_to_yojson gate
        | None -> `Null );
    ]

let trim_to_option value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let trim_opt = function
  | Some value -> trim_to_option value
  | None -> None

let dedup_strings values =
  values
  |> List.filter_map trim_to_option
  |> List.sort_uniq String.compare

let lowercase value = String.lowercase_ascii (String.trim value)

let actor_kind_of_name name =
  let normalized = String.lowercase_ascii (String.trim name) in
  if normalized = "" || normalized = "system" then
    "system"
  else if Resilience.Zombie.is_keeper_name normalized then
    "keeper"
  else
    "agent"

let task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let task_assignee_kind task =
  task_assignee task |> Option.map actor_kind_of_name

let contract_links task =
  match task.contract with
  | Some contract -> contract.links
  | None ->
      {
        operation_id = None;
        session_id = None;
        autoresearch_loop_id = None;
      }

let read_text_if_exists (config : Room.config) path =
  if Room_utils.path_exists config path then
    trim_to_option (Room_utils.read_text config path)
  else
    None

let completion_text_sources (config : Room.config) (task : Types.task)
    ~(completion_notes : string option) =
  let deliverable =
    read_text_if_exists config (Run_eio.deliverable_path config task.id)
  in
  let done_notes =
    match task.task_status with
    | Done { notes; _ } -> trim_opt notes
    | _ -> None
  in
  dedup_strings
    (List.filter_map
       (fun value -> value)
       [ trim_opt completion_notes; deliverable; done_notes ])

let text_contains_criterion sources criterion =
  let needle = lowercase criterion in
  needle <> ""
  && List.exists
       (fun source ->
         let haystack = lowercase source in
         haystack <> "" && String.contains haystack needle.[0]
         &&
         let hay_len = String.length haystack in
         let needle_len = String.length needle in
         let rec loop index =
           if index > hay_len - needle_len then false
           else if String.sub haystack index needle_len = needle then true
           else loop (index + 1)
         in
         if needle_len > hay_len then false else loop 0)
       sources

let unmet_completion_contract (config : Room.config) (task : Types.task)
    ~(completion_notes : string option) =
  match task.contract with
  | None -> []
  | Some contract ->
      let sources = completion_text_sources config task ~completion_notes in
      contract.completion_contract
      |> dedup_strings
      |> List.filter (fun criterion ->
             not (text_contains_criterion sources criterion))

let session_id_of_task task =
  contract_links task |> fun links -> trim_opt links.session_id

let operation_id_of_task task =
  contract_links task |> fun links -> trim_opt links.operation_id

let autoresearch_loop_id_of_task task =
  contract_links task |> fun links -> trim_opt links.autoresearch_loop_id

let proof_verdict_ok verdict =
  String.equal verdict "proved" || String.equal verdict "proved_strong"

let check_session_proof (config : Room.config) task =
  match session_id_of_task task with
  | None ->
      {
        evidence = "session_proof";
        outcome = Missing;
        detail = "task contract has no linked session_id";
      }
  | Some session_id ->
      let path = Team_session_store.proof_json_path config session_id in
      if not (Room_utils.path_exists config path) then
        {
          evidence = "session_proof";
          outcome = Missing;
          detail = "team session proof.json is missing";
        }
      else
        let verdict =
          try
            let json = Room_utils.read_json config path in
            U.(json |> member "verdict" |> to_string_option)
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> None
        in
        match trim_opt verdict with
        | Some verdict when proof_verdict_ok verdict ->
            {
              evidence = "session_proof";
              outcome = Satisfied;
              detail = "team session proof verdict is acceptable";
            }
        | Some verdict ->
            {
              evidence = "session_proof";
              outcome = Failed;
              detail = "team session proof verdict=" ^ verdict;
            }
        | None ->
            {
              evidence = "session_proof";
              outcome = Failed;
              detail = "team session proof verdict missing";
            }

let check_cdal_completed (config : Room.config) task =
  match session_id_of_task task with
  | None ->
      {
        evidence = "cdal_completed";
        outcome = Missing;
        detail = "task contract has no linked session_id";
      }
  | Some session_id ->
      let worker_run_ids = Team_session_store.list_worker_run_ids config session_id in
      if worker_run_ids = [] then
        {
          evidence = "cdal_completed";
          outcome = Missing;
          detail = "no worker runs recorded for linked session";
        }
      else
        let statuses =
          worker_run_ids
          |> List.map (fun worker_run_id ->
                 let path =
                   Team_session_store.worker_run_proof_path config session_id
                     worker_run_id
                 in
                 if not (Room_utils.path_exists config path) then
                   (worker_run_id, None)
                 else
                   let status =
                     try
                       let json = Room_utils.read_json config path in
                       U.(json |> member "result_status" |> to_string_option)
                     with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | _ -> None
                   in
                   (worker_run_id, trim_opt status))
        in
        let missing =
          statuses
          |> List.filter_map (fun (worker_run_id, status) ->
                 match status with
                 | None -> Some worker_run_id
                 | Some _ -> None)
        in
        let non_completed =
          statuses
          |> List.filter_map (fun (worker_run_id, status) ->
                 match status with
                 | Some "completed" -> None
                 | Some status -> Some (worker_run_id ^ ":" ^ status)
                 | None -> None)
        in
        if missing <> [] then
          {
            evidence = "cdal_completed";
            outcome = Missing;
            detail =
              "worker proof missing for " ^ String.concat ", " missing;
          }
        else if non_completed <> [] then
          {
            evidence = "cdal_completed";
            outcome = Failed;
            detail =
              "worker result_status not completed: "
              ^ String.concat ", " non_completed;
          }
        else
          {
            evidence = "cdal_completed";
            outcome = Satisfied;
            detail = "all linked worker proofs report completed";
          }

let check_run_deliverable (config : Room.config) task =
  match read_text_if_exists config (Run_eio.deliverable_path config task.id) with
  | Some _ ->
      {
        evidence = "run_deliverable";
        outcome = Satisfied;
        detail = "run deliverable is present";
      }
  | None ->
      {
        evidence = "run_deliverable";
        outcome = Missing;
        detail = "run deliverable is missing";
      }

let check_session_link task =
  match session_id_of_task task with
  | Some _ ->
      {
        evidence = "session_link";
        outcome = Satisfied;
        detail = "session link present";
      }
  | None ->
      {
        evidence = "session_link";
        outcome = Missing;
        detail = "session link missing";
      }

let check_operation_link task =
  match operation_id_of_task task with
  | Some _ ->
      {
        evidence = "operation_link";
        outcome = Satisfied;
        detail = "operation link present";
      }
  | None ->
      {
        evidence = "operation_link";
        outcome = Missing;
        detail = "operation link missing";
      }

let check_autoresearch_link (config : Room.config) task =
  match autoresearch_loop_id_of_task task with
  | None ->
      {
        evidence = "autoresearch_link";
        outcome = Missing;
        detail = "autoresearch loop link missing";
      }
  | Some loop_id -> (
      match Autoresearch.load_state ~base_path:config.base_path loop_id with
      | Some _ ->
          {
            evidence = "autoresearch_link";
            outcome = Satisfied;
            detail = "autoresearch loop state present";
          }
      | None ->
          {
            evidence = "autoresearch_link";
            outcome = Missing;
            detail = "autoresearch loop state missing";
          })

let check_evidence (config : Room.config) task evidence =
  match evidence with
  | "run_deliverable" -> check_run_deliverable config task
  | "session_link" -> check_session_link task
  | "operation_link" -> check_operation_link task
  | "autoresearch_link" -> check_autoresearch_link config task
  | "session_proof" -> check_session_proof config task
  | "cdal_completed" -> check_cdal_completed config task
  | unsupported ->
      {
        evidence = unsupported;
        outcome = Unsupported;
        detail = "unsupported deterministic evidence kind";
      }

let reasons_of_checks checks =
  checks
  |> List.filter_map (fun check ->
         match check.outcome with
         | Satisfied -> None
         | Missing | Failed | Unsupported ->
             Some (check.evidence ^ ": " ^ check.detail))

let gate_status_of_checks checks =
  if
    List.exists
      (fun check -> match check.outcome with Failed -> true | _ -> false)
      checks
  then
    Blocked
  else if
    List.exists
      (fun check -> match check.outcome with Unsupported -> true | _ -> false)
      checks
  then
    Inconclusive
  else if
    List.exists
      (fun check -> match check.outcome with Missing -> true | _ -> false)
      checks
  then
    Blocked
  else
    Ready

let evaluate_gate (config : Room.config) task required_evidence =
  let checks =
    required_evidence
    |> dedup_strings
    |> List.map (check_evidence config task)
  in
  let reasons = reasons_of_checks checks in
  { status = gate_status_of_checks checks; checks; reasons }

let strict_done_evidence (contract : Types.task_contract) =
  let links = contract.links in
  if contract.strict then
    []
    |> fun acc ->
    match trim_opt links.session_id with
    | Some _ -> "session_proof" :: "cdal_completed" :: acc
    | None -> acc
  else
    []

let evaluate ?completion_notes (config : Room.config) (task : Types.task) =
  match task.contract with
  | None ->
      {
        strict = false;
        completion_contract = [];
        unmet_completion_contract = [];
        done_gate = { status = Ready; checks = []; reasons = [] };
        inspect_gate = None;
        verify_gate = None;
      }
  | Some contract ->
      let unmet =
        unmet_completion_contract config task ~completion_notes
      in
      let done_required =
        dedup_strings (contract.required_evidence @ strict_done_evidence contract)
      in
      let done_gate = evaluate_gate config task done_required in
      let done_gate =
        if unmet = [] then
          done_gate
        else
          {
            done_gate with
            status = Blocked;
            reasons =
              done_gate.reasons
              @
              List.map
                (fun criterion ->
                  "completion_contract unmet: " ^ criterion)
                unmet;
          }
      in
      let inspect_gate =
        match dedup_strings contract.inspect_gate_evidence with
        | [] -> None
        | requirements -> Some (evaluate_gate config task requirements)
      in
      let verify_gate =
        match dedup_strings contract.verify_gate_evidence with
        | [] -> None
        | requirements -> Some (evaluate_gate config task requirements)
      in
      {
        strict = contract.strict;
        completion_contract = dedup_strings contract.completion_contract;
        unmet_completion_contract = unmet;
        done_gate;
        inspect_gate;
        verify_gate;
      }

let done_gate_allows_completion snapshot =
  snapshot.done_gate.status = Ready
  && snapshot.unmet_completion_contract = []

let task_projection_json (config : Room.config) (task : Types.task) =
  let snapshot = evaluate config task in
  `Assoc
    [
      ( "contract",
        match task.contract with
        | Some contract -> Types.task_contract_to_yojson contract
        | None -> `Null );
      ( "handoff_context",
        match task.handoff_context with
        | Some handoff_context ->
            Types.task_handoff_context_to_yojson handoff_context
        | None -> `Null );
      ("gate", task_snapshot_to_yojson snapshot);
      ("assignee_kind", Json_util.string_opt_to_json (task_assignee_kind task));
      ( "execution_links",
        Types.task_execution_links_to_yojson (contract_links task) );
    ]
