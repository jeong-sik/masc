type configuration = Enabled | Off | Disabled
type unavailable = Locked | Unreadable | Invalid_row
type snapshot = Snapshot_matching | Snapshot_missing | Snapshot_conflicting
type stage = Candidates_unrecorded | Candidates_consistent | Candidates_inconsistent | Candidates_unchecked
type hold_origin = Stored | Derived_candidates
type issue_observation = Complete_issues of Candle_payout.window_issue list
  | Snapshot_independent_issues of Candle_payout.window_issue list | Issues_unavailable
type unattributed_reason = No_candidates | All_unrelated | No_related_keepers | Window_released
type identity = { request_id : string; verification_run_id : string }
type allocation = { keeper : string; weight : int; amount_milli : int }

type payout =
  | No_recorded_obligation
  | Owed of { identity : identity; snapshot : snapshot; stage : stage }
  | Held of
      { identity : identity
      ; snapshot : snapshot
      ; origin : hold_origin
      ; issues : issue_observation
      }
  | Paid of { identity : identity; recorded_at : Candle_time.t; allocations : allocation list }
  | Unattributed of { identity : identity; recorded_at : Candle_time.t; reason : unattributed_reason }
  | Payout_failed of { identity : identity }
  | Inconsistent

type ledger = Missing | Unavailable of unavailable | Observed of payout
type t = { configuration : configuration; ledger : ledger }

let identity (waiting : Candle_payout.waiting) =
  { request_id = waiting.request_id; verification_run_id = waiting.verification_run_id }
;;

let payout_waiting events (waiting : Candle_payout.waiting) =
  let observation = Candle_payout.observe_current_pass waiting events in
  let snapshot, pass = match observation with
    | Candle_payout.Missing_snapshot -> Snapshot_missing, None
    | Conflicting_snapshots -> Snapshot_conflicting, None
    | Matching_snapshot pass -> Snapshot_matching, Some pass in
  (* A later conflicting Snapshot must not erase the evidence that admitted an
     already recorded hold. Reconstruct its issues from the exact prefix the
     ledger validated when that hold was appended; report today's Snapshot
     conflict independently. *)
  let rec stored_issues preceding = function
    | [] -> None
    | (event : Candle_event.t) :: rest ->
      (match event.body with
       | Candle_event.Candidate_window_held held
         when String.equal held.goal_id waiting.goal_id
              && String.equal held.request_id waiting.request_id
              && String.equal held.verification_run_id waiting.verification_run_id ->
         (match Candle_payout.observe_current_pass waiting (List.rev preceding) with
          | Matching_snapshot (pass : Candle_payout.pass) ->
            Some (Candle_payout.window_issues ~goal_created_at:pass.goal_created_at
              ~confirmed_at:waiting.confirmed_at held.tasks)
          | Missing_snapshot | Conflicting_snapshots -> None)
       | Candle_event.Candidate_window_held _ | Candle_event.Snapshot _ | Candle_event.Payout_owed _
       | Candle_event.Candidates _ | Candle_event.Candidates_fenced _ | Candle_event.Unattributed _
       | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _
       | Candle_event.Purchased _ | Candle_event.Granted _ | Candle_event.Gifted _
       | Candle_event.Gifted_item _ | Candle_event.Candidate_window_released _
       | Candle_event.Payout_failed _ -> stored_issues (event :: preceding) rest) in
  let identity = identity waiting in
  match Candle_payout.held_window_of waiting events with
  | Some _ -> Held { identity; snapshot; origin = Stored;
      issues = (match stored_issues [] events with Some issues -> Complete_issues issues | None -> Issues_unavailable) }
  | None ->
    (match Candle_payout.candidate_observations_of waiting events with
     | None -> Owed { identity; snapshot; stage = Candidates_unrecorded }
     | Some (tasks, provenance) ->
       let issues = match pass with
         | Some (pass : Candle_payout.pass) -> Complete_issues
             (Candle_payout.observation_issues ~provenance ~goal_created_at:pass.goal_created_at
                ~confirmed_at:waiting.confirmed_at tasks)
         | None -> Snapshot_independent_issues (Candle_payout.snapshot_independent_issues ~provenance tasks) in
       match issues with
       | Complete_issues (_ :: _) | Snapshot_independent_issues (_ :: _) ->
         Held { identity; snapshot; origin = Derived_candidates; issues }
       | Complete_issues [] ->
         let stage = match Candle_payout.validate_durable_candidates waiting events with
           | Ok () -> Candidates_consistent | Error _ -> Candidates_inconsistent in
         Owed { identity; snapshot; stage }
       | Snapshot_independent_issues [] | Issues_unavailable ->
         Owed { identity; snapshot; stage = Candidates_unchecked })
;;

let settlement ~goal_id events =
  List.find_map (fun (event : Candle_event.t) -> match event.body with
    | Candle_event.Paid paid when String.equal paid.identity.goal_id goal_id ->
      Some (Paid { identity = { request_id = paid.identity.request_id;
                               verification_run_id = paid.identity.verification_run_id };
                   recorded_at = event.at;
                   allocations = List.map (fun (a : Candle_payment.allocation) ->
                     {keeper=a.keeper; weight=a.weight; amount_milli=a.amount_milli}) paid.allocations })
    | Candle_event.Unattributed u when String.equal u.goal_id goal_id ->
      let reason = match u.reason with
        | Candle_event.No_candidates -> No_candidates
        | All_unrelated _ -> All_unrelated
        | No_related_keepers _ -> No_related_keepers
        | Window_released -> Window_released in
      Some (Unattributed {identity = {request_id = u.request_id;
                                      verification_run_id = u.verification_run_id};
                          recorded_at = event.at; reason})
    | Candle_event.Paid _ | Candle_event.Unattributed _ | Candle_event.Snapshot _
    | Candle_event.Payout_owed _ | Candle_event.Candidates _ | Candle_event.Candidates_fenced _
    | Candle_event.Candidate_window_held _ | Candle_event.Candidate_window_released _
    | Candle_event.Half_life_set _ | Candle_event.Equipped _
    | Candle_event.Purchased _ | Candle_event.Granted _ | Candle_event.Gifted _
    | Candle_event.Gifted_item _ | Candle_event.Payout_failed _ -> None) events
;;

let project ~goal_id events =
  match Candle_payout.state ~goal_id events with
  | Candle_payout.No_obligation -> No_recorded_obligation
  | Waiting waiting -> payout_waiting events waiting
  | Failed waiting -> Payout_failed { identity = identity waiting }
  | Settled -> Option.value ~default:Inconsistent (settlement ~goal_id events)
;;

let identity_fields identity =
  [ "request_id", `String identity.request_id
  ; "verification_run_id", `String identity.verification_run_id ]
;;

let snapshot_text = function
  | Snapshot_matching -> "matching"
  | Snapshot_missing -> "missing"
  | Snapshot_conflicting -> "conflicting"
;;

let issue_json = function
  | Candle_payout.Same_second {task_id; boundary; completed_at} ->
    `Assoc ["kind", `String "same_second"; "task_id", `String task_id;
            "boundary", `String (match boundary with Goal_created -> "goal_created" | Human_confirmed -> "human_confirmed");
            "completed_at", `String (Candle_time.to_rfc3339 completed_at)]
  | Task_missing {task_id} -> `Assoc ["kind", `String "task_missing"; "task_id", `String task_id]
  | Task_unobserved {task_id} -> `Assoc ["kind", `String "task_unobserved"; "task_id", `String task_id]
  | Unfenced_nonterminal {task_id} -> `Assoc ["kind", `String "unfenced_nonterminal"; "task_id", `String task_id]
  | Reversed_window {goal_created_at; confirmed_at} ->
    `Assoc ["kind", `String "reversed_window";
            "goal_created_at", `String (Candle_time.to_rfc3339 goal_created_at);
            "confirmed_at", `String (Candle_time.to_rfc3339 confirmed_at)]
;;

let payout_json = function
  | No_recorded_obligation -> `Assoc ["state", `String "no_recorded_obligation"]
  | Owed {identity; snapshot; stage} ->
    `Assoc (["state", `String "owed"; "snapshot", `String (snapshot_text snapshot);
             "stage", `String (match stage with Candidates_unrecorded -> "candidates_unrecorded"
               | Candidates_consistent -> "candidates_consistent" | Candidates_inconsistent -> "candidates_inconsistent"
               | Candidates_unchecked -> "candidates_unchecked")]
            @ identity_fields identity)
  | Held {identity; snapshot; origin; issues} ->
    `Assoc (["state", `String "held"; "snapshot", `String (snapshot_text snapshot);
             "origin", `String (match origin with Stored -> "stored" | Derived_candidates -> "derived_candidates");
             "issues", (match issues with
               | Complete_issues entries -> `Assoc ["state", `String "complete"; "entries", `List (List.map issue_json entries)]
               | Snapshot_independent_issues entries -> `Assoc ["state", `String "snapshot_independent"; "entries", `List (List.map issue_json entries)]
               | Issues_unavailable -> `Assoc ["state", `String "unavailable"]) ]
            @ identity_fields identity)
  | Paid {identity; recorded_at; allocations} ->
    `Assoc (["state", `String "paid"; "recorded_at", `String (Candle_time.to_rfc3339 recorded_at);
             "allocations", `List (List.map (fun a -> `Assoc ["keeper", `String a.keeper;
               "weight", `String (string_of_int a.weight); "amount_milli", `String (string_of_int a.amount_milli)]) allocations)]
            @ identity_fields identity)
  | Unattributed {identity; recorded_at; reason} ->
    `Assoc (["state", `String "unattributed"; "recorded_at", `String (Candle_time.to_rfc3339 recorded_at);
             "reason", `String (match reason with No_candidates -> "no_candidates" | All_unrelated -> "all_unrelated" | No_related_keepers -> "no_related_keepers" | Window_released -> "window_released")] @ identity_fields identity)
  | Payout_failed {identity} ->
    `Assoc (["state", `String "payout_failed"; "reason", `String "recorded_unreadable_due_date"] @ identity_fields identity)
  | Inconsistent -> `Assoc ["state", `String "inconsistent"]
;;

let to_yojson ~goal_id {configuration; ledger} =
  let config = match configuration with Enabled -> "enabled" | Off -> "off" | Disabled -> "disabled" in
  let ledger = match ledger with
    | Missing -> `Assoc ["state", `String "missing"]
    | Unavailable reason ->
      `Assoc ["state", `String "unavailable"; "reason", `String (match reason with
        | Locked -> "locked" | Unreadable -> "unreadable" | Invalid_row -> "invalid_row")]
    | Observed payout -> `Assoc ["state", `String "observed"; "payout", payout_json payout] in
  `Assoc ["schema", `String "masc.goal-candle-observation.v1"; "goal_id", `String goal_id;
          "config", `Assoc ["state", `String config]; "ledger", ledger;
          "execution", `Assoc ["state", `String "not_observed";
                               "reason", `String "no_complete_goal_request_index"]]
;;

(* A closed decoder shared by the TUI and other OCaml consumers. In
   particular, a missing execution field must never become "not observed" by
   default: that would hide a malformed or newer response. *)
let of_yojson ~goal_id json =
  let open Result.Syntax in
  let invalid () = Error "invalid Goal Candle observation" in
  let fields names = function
    | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
    | _ -> invalid () in
  let get name fields = List.assoc name fields in
  let str = function `String value when String.trim value <> "" -> Ok value | _ -> invalid () in
  let time json = let* value = str json in
    match Candle_time.of_rfc3339 value with Ok value -> Ok value | Error _ -> invalid () in
  let nonnegative_int json =
    let* value = str json in
    match int_of_string_opt value with
    | Some number when number >= 0 && String.equal value (string_of_int number) -> Ok number
    | Some _ | None -> invalid () in
  let identity fields =
    let* request_id = str (get "request_id" fields) in
    let* verification_run_id = str (get "verification_run_id" fields) in
    Ok {request_id; verification_run_id} in
  let snapshot = function
    | `String "matching" -> Ok Snapshot_matching
    | `String "missing" -> Ok Snapshot_missing
    | `String "conflicting" -> Ok Snapshot_conflicting
    | _ -> invalid () in
  let issue json =
    match json with
    | `Assoc entries ->
      (match List.assoc_opt "kind" entries with
       | Some (`String "same_second") ->
         let* entries = fields ["kind"; "task_id"; "boundary"; "completed_at"] json in
         let* task_id = str (get "task_id" entries) in
         let* boundary = match get "boundary" entries with
           | `String "goal_created" -> Ok Candle_payout.Goal_created
           | `String "human_confirmed" -> Ok Human_confirmed
           | _ -> invalid () in
         let* completed_at = time (get "completed_at" entries) in
         Ok (Candle_payout.Same_second {task_id; boundary; completed_at})
       | Some (`String ("task_missing" | "task_unobserved" | "unfenced_nonterminal" as kind)) ->
         let* entries = fields ["kind"; "task_id"] json in
         let* task_id = str (get "task_id" entries) in
         (match kind with
          | "task_missing" -> Ok (Candle_payout.Task_missing {task_id})
          | "task_unobserved" -> Ok (Candle_payout.Task_unobserved {task_id})
          | "unfenced_nonterminal" -> Ok (Candle_payout.Unfenced_nonterminal {task_id})
          | _ -> invalid ())
       | Some (`String "reversed_window") ->
         let* entries = fields ["kind"; "goal_created_at"; "confirmed_at"] json in
         let* goal_created_at = time (get "goal_created_at" entries) in
         let* confirmed_at = time (get "confirmed_at" entries) in
         Ok (Candle_payout.Reversed_window {goal_created_at; confirmed_at})
       | _ -> invalid ())
    | _ -> invalid () in
  let rec issues = function
    | [] -> Ok []
    | value :: rest -> let* value = issue value in let* rest = issues rest in Ok (value :: rest) in
  let payout json =
    let with_identity names json =
      let* entries = fields ("state" :: "request_id" :: "verification_run_id" :: names) json in
      let* identity = identity entries in Ok (entries, identity) in
    match json with
    | `Assoc entries ->
      (match List.assoc_opt "state" entries with
       | Some (`String "no_recorded_obligation") ->
         let* _ = fields ["state"] json in Ok No_recorded_obligation
       | Some (`String "inconsistent") -> let* _ = fields ["state"] json in Ok Inconsistent
       | Some (`String "owed") ->
         let* entries, identity = with_identity ["snapshot"; "stage"] json in
         let* snapshot = snapshot (get "snapshot" entries) in
         let* stage = match get "stage" entries with
           | `String "candidates_unrecorded" -> Ok Candidates_unrecorded
           | `String "candidates_consistent" -> Ok Candidates_consistent
           | `String "candidates_inconsistent" -> Ok Candidates_inconsistent
           | `String "candidates_unchecked" -> Ok Candidates_unchecked
           | _ -> invalid () in
         Ok (Owed {identity; snapshot; stage})
       | Some (`String "held") ->
         let* entries, identity = with_identity ["snapshot"; "origin"; "issues"] json in
         let* snapshot = snapshot (get "snapshot" entries) in
         let* origin = match get "origin" entries with
           | `String "stored" -> Ok Stored | `String "derived_candidates" -> Ok Derived_candidates
           | _ -> invalid () in
         let issues_json = get "issues" entries in
         let* issues = match issues_json with
           | `Assoc fields' ->
             (match List.assoc_opt "state" fields' with
              | Some (`String "unavailable") -> let* _ = fields ["state"] issues_json in Ok Issues_unavailable
              | Some (`String ("complete" | "snapshot_independent" as state)) ->
                let* fields' = fields ["state"; "entries"] issues_json in
                let* values = match get "entries" fields' with `List values -> issues values | _ -> invalid () in
                if String.equal state "complete" then Ok (Complete_issues values) else Ok (Snapshot_independent_issues values)
              | _ -> invalid ())
           | _ -> invalid () in
         Ok (Held {identity; snapshot; origin; issues})
       | Some (`String "paid") ->
         let* entries, identity = with_identity ["recorded_at"; "allocations"] json in
         let* recorded_at = time (get "recorded_at" entries) in
         let rec allocations seen = function
           | [] -> Ok []
           | json :: rest ->
             let* fields = fields ["keeper"; "weight"; "amount_milli"] json in
             let* keeper = str (get "keeper" fields) in
             let* () = if List.mem keeper seen then invalid () else Ok () in
             let* weight = nonnegative_int (get "weight" fields) in
             let* amount_milli = nonnegative_int (get "amount_milli" fields) in
             let* rest = allocations (keeper :: seen) rest in
             Ok ({keeper; weight; amount_milli} :: rest) in
         let* allocations = match get "allocations" entries with
           | `List values -> allocations [] values | _ -> invalid () in
         Ok (Paid {identity; recorded_at; allocations})
       | Some (`String "unattributed") ->
         let* entries, identity = with_identity ["recorded_at"; "reason"] json in
         let* recorded_at = time (get "recorded_at" entries) in
         let* reason = match get "reason" entries with
           | `String "no_candidates" -> Ok No_candidates | `String "all_unrelated" -> Ok All_unrelated
           | `String "no_related_keepers" -> Ok No_related_keepers
           | `String "window_released" -> Ok Window_released | _ -> invalid () in
         Ok (Unattributed {identity; recorded_at; reason})
       | Some (`String "payout_failed") ->
         let* entries, identity = with_identity ["reason"] json in
         (match get "reason" entries with `String "recorded_unreadable_due_date" -> Ok (Payout_failed {identity}) | _ -> invalid ())
       | _ -> invalid ())
    | _ -> invalid () in
  let* root = fields ["schema"; "goal_id"; "config"; "ledger"; "execution"] json in
  let* () = match get "schema" root, get "goal_id" root with
    | `String "masc.goal-candle-observation.v1", `String id when String.equal id goal_id -> Ok ()
    | _ -> invalid () in
  let* execution = fields ["state"; "reason"] (get "execution" root) in
  let* () = match get "state" execution, get "reason" execution with
    | `String "not_observed", `String "no_complete_goal_request_index" -> Ok () | _ -> invalid () in
  let* config = fields ["state"] (get "config" root) in
  let* configuration = match get "state" config with
    | `String "enabled" -> Ok Enabled | `String "off" -> Ok Off | `String "disabled" -> Ok Disabled
    | _ -> invalid () in
  let ledger_json = get "ledger" root in
  let* ledger = match ledger_json with
    | `Assoc entries ->
      (match List.assoc_opt "state" entries with
       | Some (`String "missing") -> let* _ = fields ["state"] ledger_json in Ok Missing
       | Some (`String "unavailable") ->
         let* entries = fields ["state"; "reason"] ledger_json in
         (match get "reason" entries with
          | `String "locked" -> Ok (Unavailable Locked) | `String "unreadable" -> Ok (Unavailable Unreadable)
          | `String "invalid_row" -> Ok (Unavailable Invalid_row) | _ -> invalid ())
       | Some (`String "observed") ->
         let* entries = fields ["state"; "payout"] ledger_json in
         let* payout = payout (get "payout" entries) in Ok (Observed payout)
       | _ -> invalid ())
    | _ -> invalid () in
  Ok {configuration; ledger}
;;
