let () = Candle_status.install_appraiser_check (fun () -> Ok ())

(** Settling a confirmed payout (RFC-goal-candle-ledger 3.2, 3.4), through
    [Candle_appraise.settle_one] on a real ledger file. Only the model is
    replaced, by a runner that answers from the request it is given. Each test
    fixes one thing the other Candle suites leave open: which keepers a payout
    is shared between when some Tasks are unrelated, what happens when another
    writer settles the payout while the model is being asked, and that an
    answer which breaks a rule never reaches the ledger. *)

open Alcotest

module A = Candle_appraisal
module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)
let now () = 1_790_700_000.

(* {1 Fixtures} *)

let temp_dir () =
  let path = Filename.temp_file "candle_settlement_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir)
  then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)
;;

let enable base_path =
  let path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path in
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc {|[payout]
weight_max = 10
deduction_rate = 10
deduction_floor = 200
[payout.grades_milli]
trivial = 1000
small = 2000
medium = 3000
large = 4000
epic = 5000
|})
;;

let events base_path =
  match Candle_ledger.read ~base_path with
  | Ok view -> Candle_ledger.events view
  | Error error -> failf "%s" (Candle_ledger.read_error_to_string error)
;;

let kinds base_path = List.map (fun (event : E.t) -> E.kind event.body) (events base_path)

let append base_path rows =
  match Candle_ledger.update ~base_path (fun _ -> Ok (rows, ())) with
  | Ok () -> ()
  | Error error -> failf "%s" (Candle_ledger.update_error_to_string Fun.id error)
;;

let goal_id = "goal-1"
let request_id = "req-1"
let run_id = "run-1"
let passed_at = at "2026-09-28T06:32:00Z"
let done_at = at "2026-09-25T00:00:00Z"

let found title assignee = E.Found { title; assignee = Some assignee; status = E.Done { completed_at = done_at } }

(* keeper-a and keeper-b are keepers. Whoever holds t-x is not, so t-x is a
   candidate Task that can never pay anyone. *)
let task_rows =
  [ "t-a", found "Store the ledger" "keeper-a"
  ; "t-b", found "Test the ledger" "keeper-b"
  ; "t-x", found "The operator's part" "outsider"
  ]
;;

(* The Goal was due 2026-09-26 and passed 30 hours later: 700 of every 1000
   milli-candle are paid (deduction rate 10 a hour, floor 200). *)
let rows : E.t list =
  [ { at = passed_at
    ; body =
        E.Snapshot
          { goal_id
          ; request_id
          ; verification_run_id = run_id
          ; criterion_revision = "rev-1"
          ; passed_at
          ; goal_created_at = at "2026-09-20T00:00:00Z"
          ; due_date = Some "2026-09-26"
          ; title = "Ship the ledger"
          ; metric = Some "accepted scenarios"
          ; target_value = Some "10"
          ; linked_task_ids = [ "t-a"; "t-b"; "t-x" ]
          }
    }
  ; { at = at "2026-09-29T05:00:00Z"
    ; body =
        E.Payout_owed
          { goal_id
          ; request_id
          ; verification_run_id = run_id
          ; passed_at
          ; confirmed_at = at "2026-09-29T05:00:00Z"
          }
    }
  ; { at = at "2026-09-29T05:10:00Z"
    ; body =
        E.Candidates
          { goal_id
          ; request_id
          ; verification_run_id = run_id
          ; tasks = task_rows
          ; candidate_task_ids = [ "t-a"; "t-b"; "t-x" ]
          ; candidate_keepers = [ "keeper-a"; "keeper-b" ]
          }
    }
  ]
;;

let with_seeded_payout f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () ->
       enable base_path;
       append base_path rows;
       match Candle_payout.waiting (events base_path) with
       | [ waiting ] -> f base_path waiting
       | other -> failf "expected one waiting payout, found %d" (List.length other))
;;

(* {1 The model} *)

let trace id : A.trace = { run_id = id; slot_id = "fixture.slot" }

(* A runner answers from the request alone, as the real one does, and keeps the
   requests it was given. *)
let runner
      ?(grade = Candle_grade.Medium)
      ~relation
      ~weights
      calls
      ~(identity : A.identity)
      request
  =
  calls := !calls @ [ request ];
  let decision =
    match request with
    | A.Grade _ -> A.Grade_decided grade
    | A.Relation r -> A.Relation_decided (relation r.task_title)
    | A.Weights w -> A.Weights_decided (weights w.keepers)
  in
  Ok
    { A.decision
    ; trace = trace (Printf.sprintf "%s:%s:%d" identity.goal_id (A.stage request) (List.length !calls))
    }
;;

let all_related (_ : string) = A.Related
let one_each keepers = List.map (fun name -> name, 1) keepers

let weights_requests calls =
  List.filter_map
    (function
      | A.Weights w -> Some (w.keepers, List.map (fun (task : A.task) -> task.title) w.tasks)
      | A.Grade _ | A.Relation _ -> None)
    !calls
;;

let relation_requests calls =
  List.filter_map
    (function
      | A.Relation r -> Some r.task_title
      | A.Grade _ | A.Weights _ -> None)
    !calls
;;

(* {1 Outcomes} *)

let outcome_text = function
  | Candle_appraise.Settled goal -> "settled " ^ goal
  | Candle_appraise.Superseded goal -> "superseded " ^ goal
  | Candle_appraise.Retry_later { goal_id; detail } -> Printf.sprintf "retry later %s: %s" goal_id detail
  | Candle_appraise.Rejected { goal_id; detail } -> Printf.sprintf "rejected %s: %s" goal_id detail
;;

let outcome = testable (fun ppf value -> Format.pp_print_string ppf (outcome_text value)) ( = )

let is_rejected = function
  | Candle_appraise.Rejected _ -> true
  | Candle_appraise.Settled _ | Candle_appraise.Superseded _ | Candle_appraise.Retry_later _ -> false
;;

let settle base_path waiting appraise = Candle_appraise.settle_one ~now ~appraise ~base_path waiting

let paid_rows base_path =
  List.filter_map
    (fun (event : E.t) ->
       match event.body with
       | E.Paid payment -> Some payment
       | E.Snapshot _ | E.Payout_owed _ | E.Candidates _ | E.Unattributed _ | E.Payout_failed _ -> None)
    (events base_path)
;;

let balance base_path keeper =
  match Candle_balance.of_events (events base_path) with
  | Ok state -> Candle_balance.balance state ~keeper
  | Error error -> failf "%s" (Candle_balance.error_to_string error)
;;

let still_waiting base_path =
  match Candle_payout.state ~goal_id (events base_path) with
  | Candle_payout.Waiting _ -> true
  | Candle_payout.No_obligation | Candle_payout.Failed _ | Candle_payout.Settled -> false
;;

(* {1 Who is asked and who is paid} *)

(* keeper-a's Task is related and keeper-b's is not. The weights request must ask
   for keeper-a alone, and only keeper-b's share is left out of the payment. The
   operator's Task is judged too (every candidate Task is) and is related, which
   pays nobody. *)
let test_only_the_keepers_with_related_work_are_asked_for_weights_and_paid () =
  with_seeded_payout
  @@ fun base_path waiting ->
  let calls = ref [] in
  let relation = function
    | "Test the ledger" -> A.Unrelated
    | _ -> A.Related
  in
  check
    outcome
    "settled"
    (Candle_appraise.Settled goal_id)
    (settle base_path waiting (runner ~relation ~weights:one_each calls));
  check
    (list string)
    "every candidate Task was judged, one request each"
    [ "Store the ledger"; "Test the ledger"; "The operator's part" ]
    (relation_requests calls);
  check
    (list (pair (list string) (list string)))
    "the weights request names keeper-a and its Task only"
    [ [ "keeper-a" ], [ "Store the ledger" ] ]
    (weights_requests calls);
  (match paid_rows base_path with
   | [ payment ] ->
     check
       (list string)
       "the payment is shared between the related keepers"
       [ "keeper-a" ]
       (List.map (fun (a : Candle_payment.allocation) -> a.keeper) payment.allocations);
     check int "the whole total is one keeper's share" 3000 (List.hd payment.allocations).share_milli;
     check
       (list (pair string bool))
       "the payment keeps every judgment"
       [ "t-a", true; "t-b", false; "t-x", true ]
       (List.map
          (fun (r : A.task_relation) -> r.task_id, r.relation = A.Related)
          payment.relations)
   | other -> failf "expected one Paid row, found %d" (List.length other));
  check int "keeper-a is credited after the 30-hour deduction" 2100 (balance base_path "keeper-a");
  check int "keeper-b is credited nothing" 0 (balance base_path "keeper-b")
;;

(* Only the operator's Task is related. Nobody with a keeper is to be paid, so the
   payout closes with the decisions kept and no weights are asked for. *)
let test_related_work_of_a_non_keeper_closes_the_payout_without_paying () =
  with_seeded_payout
  @@ fun base_path waiting ->
  let calls = ref [] in
  let relation = function
    | "The operator's part" -> A.Related
    | _ -> A.Unrelated
  in
  check
    outcome
    "settled"
    (Candle_appraise.Settled goal_id)
    (settle base_path waiting (runner ~relation ~weights:one_each calls));
  check (list (pair (list string) (list string))) "no weights were asked for" [] (weights_requests calls);
  check (list string) "no payment" [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ] (kinds base_path);
  (match List.rev (events base_path) with
   | { E.body = E.Unattributed { reason = E.No_related_keepers attribution; _ }; _ } :: _ ->
     check int "the judgments are kept" 3 (List.length attribution.relations)
   | _ -> fail "the payout did not close as no_related_keepers");
  check int "nobody is credited" 0 (balance base_path "keeper-a")
;;

(* {1 Two writers} *)

(* Another worker settles the payout while this one waits for the model. This one
   must notice at the append, step aside, and pay nothing a second time. *)
let test_a_payout_settled_by_another_worker_meanwhile_is_left_alone () =
  with_seeded_payout
  @@ fun base_path waiting ->
  let raced = ref None in
  let racing ~(identity : A.identity) request =
    if Option.is_none !raced
    then
      raced
      := Some (settle base_path waiting (runner ~relation:all_related ~weights:one_each (ref [])));
    runner ~relation:all_related ~weights:one_each (ref []) ~identity request
  in
  check outcome "this worker steps aside" (Candle_appraise.Superseded goal_id) (settle base_path waiting racing);
  check
    (option outcome)
    "the other worker settled it"
    (Some (Candle_appraise.Settled goal_id))
    !raced;
  check int "one Paid row" 1 (List.length (paid_rows base_path));
  (* 3000 shared by two keepers is 1500 each, and 700 of every 1000 is paid. *)
  check int "keeper-a is credited once" 1050 (balance base_path "keeper-a");
  check int "keeper-b is credited once" 1050 (balance base_path "keeper-b")
;;

(* The payout is closed by something that is not a payment while the model is
   being asked. Paying it now would put a Paid row after the closing row. *)
let test_a_payout_closed_meanwhile_is_not_paid () =
  with_seeded_payout
  @@ fun base_path waiting ->
  let closed = ref false in
  let closing ~(identity : A.identity) request =
    if not !closed
    then (
      closed := true;
      append
        base_path
        [ { E.at = at "2026-09-29T06:00:00Z"
          ; body =
              E.Unattributed
                { goal_id; request_id; verification_run_id = run_id; reason = E.No_candidates }
          }
        ]);
    runner ~relation:all_related ~weights:one_each (ref []) ~identity request
  in
  check outcome "steps aside" (Candle_appraise.Superseded goal_id) (settle base_path waiting closing);
  check
    (list string)
    "the closing row is the last row"
    [ "snapshot"; "payout_owed"; "candidates"; "unattributed" ]
    (kinds base_path);
  check int "nobody is credited" 0 (balance base_path "keeper-a")
;;

let test_settling_a_settled_payout_again_pays_nothing_more () =
  with_seeded_payout
  @@ fun base_path waiting ->
  let calls = ref [] in
  let appraise = runner ~relation:all_related ~weights:one_each calls in
  check outcome "first" (Candle_appraise.Settled goal_id) (settle base_path waiting appraise);
  let rows_after_first = kinds base_path in
  let calls_after_first = List.length !calls in
  check outcome "second" (Candle_appraise.Superseded goal_id) (settle base_path waiting appraise);
  check (list string) "no row was added" rows_after_first (kinds base_path);
  check int "the model was not asked again" calls_after_first (List.length !calls);
  check int "one Paid row" 1 (List.length (paid_rows base_path))
;;

(* {1 An answer that breaks a rule} *)

let test_an_answer_that_breaks_a_rule_writes_nothing_and_leaves_the_payout_waiting () =
  List.iter
    (fun (label, weights) ->
       with_seeded_payout
       @@ fun base_path waiting ->
       let result =
         settle base_path waiting (runner ~relation:all_related ~weights (ref []))
       in
       check bool (label ^ ": rejected") true (is_rejected result);
       check (list string) (label ^ ": nothing was written") [ "snapshot"; "payout_owed"; "candidates" ] (kinds base_path);
       check bool (label ^ ": still waiting") true (still_waiting base_path))
    [ "above weight_max", (fun keepers -> List.map (fun name -> name, 11) keepers)
    ; "negative", (fun keepers -> List.map (fun name -> name, -1) keepers)
    ; "all zero", (fun keepers -> List.map (fun name -> name, 0) keepers)
    ; "a stranger for a keeper", (fun keepers -> ("stranger", 1) :: List.tl (one_each keepers))
    ; "a keeper left out", (fun keepers -> [ List.hd (one_each keepers) ])
    ]
;;

let () =
  run
    "candle_settlement"
    [ ( "who is asked and who is paid"
      , [ test_case
            "only the keepers with related work are asked for weights and paid"
            `Quick
            test_only_the_keepers_with_related_work_are_asked_for_weights_and_paid
        ; test_case
            "related work of a non-keeper closes the payout without paying"
            `Quick
            test_related_work_of_a_non_keeper_closes_the_payout_without_paying
        ] )
    ; ( "two writers"
      , [ test_case
            "a payout settled by another worker meanwhile is left alone"
            `Quick
            test_a_payout_settled_by_another_worker_meanwhile_is_left_alone
        ; test_case
            "a payout closed meanwhile is not paid"
            `Quick
            test_a_payout_closed_meanwhile_is_not_paid
        ; test_case
            "settling a settled payout again pays nothing more"
            `Quick
            test_settling_a_settled_payout_again_pays_nothing_more
        ] )
    ; ( "an answer that breaks a rule"
      , [ test_case
            "writes nothing and leaves the payout waiting"
            `Quick
            test_an_answer_that_breaks_a_rule_writes_nothing_and_leaves_the_payout_waiting
        ] )
    ]
;;
