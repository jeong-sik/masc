(* RFC-0361 D4 — completion-authority review observation record.

   The registry exists because a review that deferred, raised, or rejected on
   the evidence contract previously left no durable trace: only the paths that
   committed a verdict emitted a [task_completion_verdict] event. These cases
   pin that every outcome constructor survives a write/replay round trip with
   its detail intact, and that an outcome label this module did not write is an
   [Error] rather than a permissive default.

   Isolated: each case gets its own temp path and the process-wide
   {!Verification_run_registry.global} is never touched. *)

open Alcotest
module R = Masc.Verification_run_registry
module E = Masc.Verification_run_registry

module Lifecycle = Masc.Run_registry_core.Global (struct
    type t = int

    let initial = 0
  end)

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let fresh_path suffix =
  let path = Filename.temp_file "verification-runs-" suffix in
  remove_if_exists path;
  path
;;

let field json key =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let str json key =
  match field json key with
  | Some (`String value) -> Some value
  | _ -> None
;;

let contains_substring value needle =
  let value_length = String.length value in
  let needle_length = String.length needle in
  let rec loop index =
    if needle_length = 0
    then true
    else if index + needle_length > value_length
    then false
    else if String.sub value index needle_length = needle
    then true
    else loop (index + 1)
  in
  loop 0
;;

let register t ~verification_id ~started_at =
  R.register_running
    t
    ~verification_id
    ~task_id:"task-136"
    ~producer:"keeper-kidsnote-agent"
    ~authority_kind:"system_llm_agent"
    ~authority_actor:("system-llm-agent-" ^ verification_id)
    ~started_at
;;

(* Every outcome constructor, each with the detail a surface must be able to
   show. Reused by the label, serialization and replay cases so a new
   constructor fails all three at once instead of silently skipping them. *)
let all_outcomes : (string * E.outcome) list =
  [ "approved", E.Approved
  ; "rejected", E.Rejected { reason = "aria attributes are not committed" }
  ; "contract_rejected", E.Contract_rejected { detail = "missing required artifact" }
  ; "not_reviewed", E.Not_reviewed { gate = "evaluator_unavailable"; detail = "no runtime" }
  ; "commit_failed", E.Commit_failed { detail = "verification id mismatch" }
  ; "raised", E.Raised { detail = "Failure(\"boom\")" }
  ]
;;

let test_running_before_completion () =
  let t = R.create () in
  register t ~verification_id:"vrf-running" ~started_at:100.0;
  match R.get t ~verification_id:"vrf-running" with
  | None -> fail "registered review should be tracked"
  | Some run ->
    check string "status" "running" (R.status_label run.status);
    check string "task" "task-136" run.task_id;
    check string "producer" "keeper-kidsnote-agent" run.producer;
    (* A running review carries no elapsed time — a surface must not read one. *)
    check
      (option string)
      "no elapsed while running"
      None
      (Option.map Yojson.Safe.to_string (field (R.run_to_yojson run) "elapsed_s"))
;;

let test_every_outcome_has_a_distinct_label () =
  let labels = List.map (fun (_, outcome) -> E.outcome_label outcome) all_outcomes in
  let expected = List.map fst all_outcomes in
  check (list string) "labels match the wire vocabulary" expected labels;
  check
    int
    "labels are distinct"
    (List.length expected)
    (List.length (List.sort_uniq String.compare labels))
;;

let test_outcome_detail_reaches_the_surface () =
  List.iter
    (fun (label, outcome) ->
       let t = R.create () in
       register t ~verification_id:"vrf-detail" ~started_at:10.0;
       R.mark_completed
         t
         ~verification_id:"vrf-detail"
         ~outcome
         ~evaluator_runtime:"cross-verifier"
         ~elapsed_s:2.5
         ();
       match R.get t ~verification_id:"vrf-detail" with
       | None -> fail "completed review should stay tracked"
       | Some run ->
         let json = R.run_to_yojson run in
         check string ("status " ^ label) label (R.status_label run.status);
         check
           (option string)
           ("evaluator_runtime " ^ label)
           (Some "cross-verifier")
           (str json "evaluator_runtime");
         (* Approved is the only outcome with nothing to explain; every failure
            shape must carry an operator-readable cause, never a bare label. *)
         let cause =
           match str json "reason", str json "detail" with
           | Some value, _ | _, Some value -> Some value
           | None, None -> None
         in
         (match outcome with
          | E.Approved -> check (option string) "approved has no cause" None cause
          | _ ->
            check bool ("cause present for " ^ label) true (Option.is_some cause)))
    all_outcomes
;;

let test_outcomes_survive_replay () =
  List.iter
    (fun (label, outcome) ->
       let path = fresh_path (".{" ^ label ^ "}.jsonl") in
       let t = R.create ~path () in
       register t ~verification_id:"vrf-replay" ~started_at:50.0;
       R.mark_completed t ~verification_id:"vrf-replay" ~outcome ~elapsed_s:1.0 ();
       let replayed = R.replay path in
       (match R.get replayed ~verification_id:"vrf-replay" with
        | None -> fail ("completed review lost on replay: " ^ label)
        | Some run ->
          check string ("replayed status " ^ label) label (R.status_label run.status);
          check
            string
            ("replayed detail " ^ label)
            (Yojson.Safe.to_string (R.run_to_yojson run))
            (Yojson.Safe.to_string
               (R.run_to_yojson (Option.get (R.get t ~verification_id:"vrf-replay")))));
       remove_if_exists path)
    all_outcomes
;;

let test_replay_drops_running_reviews () =
  let path = fresh_path ".running.jsonl" in
  let t = R.create ~path () in
  register t ~verification_id:"vrf-done" ~started_at:10.0;
  R.mark_completed t ~verification_id:"vrf-done" ~outcome:E.Approved ~elapsed_s:1.0 ();
  register t ~verification_id:"vrf-stale" ~started_at:20.0;
  let replayed = R.replay path in
  (* The review fiber dies with the process and the authority rescans
     AwaitingVerification at boot, so a replayed running entry would name a
     review that is not happening. *)
  check
    bool
    "stale running review dropped"
    true
    (Option.is_none (R.get replayed ~verification_id:"vrf-stale"));
  check
    bool
    "completed review kept"
    true
    (Option.is_some (R.get replayed ~verification_id:"vrf-done"));
  remove_if_exists path
;;

let test_retry_replaces_the_prior_attempt () =
  let t = R.create () in
  register t ~verification_id:"vrf-retry" ~started_at:10.0;
  R.mark_completed
    t
    ~verification_id:"vrf-retry"
    ~outcome:(E.Not_reviewed { gate = "invalid_verdict"; detail = "no tool call" })
    ~elapsed_s:1.0
    ();
  (* A deferred review is retried under a fresh authority actor; the table must
     name the live attempt, not accumulate one row per retry. *)
  R.register_running
    t
    ~verification_id:"vrf-retry"
    ~task_id:"task-136"
    ~producer:"keeper-kidsnote-agent"
    ~authority_actor:"system-llm-agent-second"
    ~authority_kind:"system_llm_agent"
    ~started_at:20.0;
  check int "one row per verification" 1 (List.length (R.list_runs t));
  match R.get t ~verification_id:"vrf-retry" with
  | None -> fail "retried review should be tracked"
  | Some run ->
    check string "newest attempt is live" "running" (R.status_label run.status);
    check string "newest actor" "system-llm-agent-second" run.authority_actor
;;

let test_unknown_completion_is_not_persisted () =
  let path = fresh_path ".unknown-id.jsonl" in
  let t = R.create ~path () in
  R.mark_completed
    t
    ~verification_id:"vrf-unknown"
    ~outcome:E.Approved
    ~elapsed_s:1.0
    ();
  check int "unknown completion creates no row" 0 (List.length (R.list_runs t));
  check bool "unknown completion writes no event" false (Sys.file_exists path)
;;

let test_unknown_outcome_label_is_an_error () =
  let path = fresh_path ".unknown-outcome.jsonl" in
  let content =
    String.concat
      "\n"
      [ {|{"event":"register","id":"vrf-unknown","started_at":1.0,"registration":{"task_id":"task-136","producer":"keeper","authority_kind":"system_llm_agent","authority_actor":"reviewer"}}|}
      ; {|{"event":"complete","id":"vrf-unknown","completion":{"outcome":"probably_fine","elapsed_s":1.0}}|}
      ; ""
      ]
  in
  Fs_compat.save_file path content;
  let replayed = R.replay path in
  check bool "unknown outcome is not replayed" true
    (Option.is_none (R.get replayed ~verification_id:"vrf-unknown"));
  check bool "unknown outcome evidence is preserved" true
    (contains_substring (Fs_compat.load_file path) "probably_fine");
  remove_if_exists path
;;

let test_missing_outcome_payload_is_an_error () =
  let path = fresh_path ".missing-outcome-detail.jsonl" in
  let content =
    String.concat
      "\n"
      [ {|{"event":"register","id":"vrf-bare","started_at":1.0,"registration":{"task_id":"task-136","producer":"keeper","authority_kind":"system_llm_agent","authority_actor":"reviewer"}}|}
      ; {|{"event":"complete","id":"vrf-bare","completion":{"outcome":"rejected","elapsed_s":1.0}}|}
      ; ""
      ]
  in
  Fs_compat.save_file path content;
  let replayed = R.replay path in
  check bool "reasonless rejection is not replayed" true
    (Option.is_none (R.get replayed ~verification_id:"vrf-bare"));
  check string "malformed completion is not compacted away" content
    (Fs_compat.load_file path);
  remove_if_exists path
;;

let test_completed_runs_are_pruned () =
  let t = R.create () in
  let total = R.max_completed_retained + 8 in
  for i = 1 to total do
    let verification_id = Printf.sprintf "vrf-%03d" i in
    register t ~verification_id ~started_at:(float_of_int i);
    R.mark_completed t ~verification_id ~outcome:E.Approved ~elapsed_s:0.5 ()
  done;
  check
    int
    "completed runs bounded"
    R.max_completed_retained
    (List.length (R.list_runs t));
  check
    bool
    "newest retained"
    true
    (Option.is_some (R.get t ~verification_id:(Printf.sprintf "vrf-%03d" total)));
  check
    bool
    "oldest evicted"
    true
    (Option.is_none (R.get t ~verification_id:"vrf-001"))
;;

let test_global_lifecycle_rejects_reinstallation () =
  check int "pre-boot registry" 0 (Lifecycle.current ());
  (match Lifecycle.install 1 with
   | Ok () -> ()
   | Error Lifecycle.Already_installed -> fail "first installation was rejected");
  check int "installed registry" 1 (Lifecycle.current ());
  (match Lifecycle.install 2 with
   | Ok () -> fail "second installation replaced the owner"
   | Error Lifecycle.Already_installed -> ());
  check int "first owner remains active" 1 (Lifecycle.current ())
;;

let () =
  run
    "verification_run_registry"
    [ ( "rfc-0361-d4"
      , [ test_case "running review is visible before it ends" `Quick test_running_before_completion
        ; test_case
            "every outcome has a distinct wire label"
            `Quick
            test_every_outcome_has_a_distinct_label
        ; test_case
            "failure outcomes carry an operator-readable cause"
            `Quick
            test_outcome_detail_reaches_the_surface
        ; test_case "every outcome survives replay" `Quick test_outcomes_survive_replay
        ; test_case
            "replay drops running reviews"
            `Quick
            test_replay_drops_running_reviews
        ; test_case
            "a retry replaces its prior attempt"
            `Quick
            test_retry_replaces_the_prior_attempt
        ; test_case
            "unknown completion is logged without a disk-only event"
            `Quick
            test_unknown_completion_is_not_persisted
        ; test_case
            "unknown outcome label is an error"
            `Quick
            test_unknown_outcome_label_is_an_error
        ; test_case
            "rejected without a reason is an error"
            `Quick
            test_missing_outcome_payload_is_an_error
        ; test_case "completed runs are pruned" `Quick test_completed_runs_are_pruned
        ; test_case
            "global registry has one installation owner"
            `Quick
            test_global_lifecycle_rejects_reinstallation
        ] )
    ]
;;
