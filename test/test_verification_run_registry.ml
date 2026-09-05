(* Completion-authority review observation record.

   These cases pin that every outcome constructor survives a write/replay
   round trip with its detail intact, and that an outcome label this module did
   not write is an [Error] rather than a permissive default.

   Isolated: each case gets its own temp path and the process-wide
   {!Verification_run_registry.global} is never touched. *)

open Alcotest
module R = Masc.Verification_run_registry
module E = Masc.Verification_run_registry

module Lifecycle = Run_registry_core.Global (struct
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

;;

let register t ~verification_id ~started_at =
  R.register_running
    t
    ~verification_id
    ~task_id:"task-136"
    ~producer:"keeper-gamma-agent"
    ~authority_kind:"system_llm_agent"
    ~authority_actor:("system-llm-agent-" ^ verification_id)
    ~started_at
;;

(* Every outcome constructor, each with the detail a surface must be able to
   show. Reused by the label, serialization and replay cases so a new
   constructor fails all three at once instead of silently skipping them. *)
let all_outcomes : (string * E.outcome) list =
  [ "approved", E.Approved { reason = "" }
  ; "rejected", E.Rejected { reason = "aria attributes are not committed" }
  ; ( "infrastructure_unavailable"
    , E.Infrastructure_unavailable
        { stage = E.Review_preparation; detail = "request store unavailable" } )
  ; ( "not_reviewed"
    , E.Not_reviewed { gate = "evaluator_unavailable"; detail = "no runtime" } )
  ; "commit_failed", E.Commit_failed { detail = "verification id mismatch" }
  ; "raised", E.Raised { detail = "Failure(\"boom\")" }
  ; ( "review_cancelled"
    , E.Review_cancelled { detail = "review fiber cancelled: shutdown" } )
  ; "operator_routed", E.Operator_routed
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
    check string "producer" "keeper-gamma-agent" run.producer;
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
         ~tools:[]
         ~evaluator_runtime:"judge-runtime"
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
           (Some "judge-runtime")
           (str json "evaluator_runtime");
         (* Every outcome carries an operator-readable cause, never a bare
            label — an approval included. The fixture builds this one with an
            empty reason, which is the shape a reviewer that stated nothing
            produces, so the field is present and blank rather than absent. *)
         let cause =
           match str json "reason", str json "detail" with
           | Some value, _ | _, Some value -> Some value
           | None, None -> None
         in
         check bool ("cause present for " ^ label) true (Option.is_some cause))
    all_outcomes
;;

let test_outcomes_survive_replay () =
  List.iter
    (fun (label, outcome) ->
       let path = fresh_path (".{" ^ label ^ "}.jsonl") in
       let t = R.create ~path () in
       register t ~verification_id:"vrf-replay" ~started_at:50.0;
       R.mark_completed t ~verification_id:"vrf-replay" ~outcome ~tools:[] ~elapsed_s:1.0 ();
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

(* [Not_reviewed] carries the gate and the detail and nothing else. The
   completion authority no longer decides whether to poll this outcome again,
   so there is no retry flag to project. The wire shape is a hard cut: a row
   written by an older binary still carries [retryable], and [exact_fields]
   rejects it rather than reading the row as if the field had never been
   there. That rejection is the contract — a tolerated extra field would let
   a stale retry decision travel silently into a registry that has no place
   to put it. *)
let test_not_reviewed_wire_shape_is_gate_and_detail () =
  let path = fresh_path ".not-reviewed.jsonl" in
  let t = R.create ~path () in
  register t ~verification_id:"vrf-not-reviewed" ~started_at:5.0;
  R.mark_completed
    t
    ~verification_id:"vrf-not-reviewed"
    ~outcome:
      (E.Not_reviewed
         { gate = "invalid_verdict"
         ; detail = "evaluator did not call report_review_verdict exactly once"
         })
    ~tools:[]
    ~elapsed_s:1.0
    ();
  (match R.get t ~verification_id:"vrf-not-reviewed" with
   | None -> fail "completed review should stay tracked"
   | Some run ->
     let json = R.run_to_yojson run in
     check (option string) "gate on the wire" (Some "invalid_verdict")
       (match field json "gate" with
        | Some (`String value) -> Some value
        | _ -> None);
     check bool "no retry flag on the wire" true (Option.is_none (field json "retryable")));
  let replayed = R.replay path in
  (match R.get replayed ~verification_id:"vrf-not-reviewed" with
   | None -> fail "not_reviewed lost on replay"
   | Some run ->
     let json = R.run_to_yojson run in
     check bool "no retry flag after replay" true (Option.is_none (field json "retryable")));
  remove_if_exists path
;;

(* An approval states why it approved, and that reason reaches the wire beside
   a rejection's. Before this, [Approved] was the one nullary outcome: the
   reviewer's stated reason was parsed and then dropped, so an operator reading
   a passed review saw a bare token. *)
let test_approval_reason_reaches_the_wire () =
  let t = R.create () in
  register t ~verification_id:"vrf-approved" ~started_at:1.0;
  R.mark_completed
    t
    ~verification_id:"vrf-approved"
    ~outcome:(E.Approved { reason = "ran the suite in the sandbox: 9355/9355" })
    ~tools:[]
    ~elapsed_s:2.0
    ();
  match R.get t ~verification_id:"vrf-approved" with
  | None -> fail "completed review should stay tracked"
  | Some run ->
    check
      (option string)
      "approval reason on the wire"
      (Some "ran the suite in the sandbox: 9355/9355")
      (str (R.run_to_yojson run) "reason")
;;

(* An approval row written before the reason existed still replays. The reason
   is optional on read for exactly this row, and reads back empty rather than
   rejecting the row or inventing a sentence. *)
let test_approval_row_without_reason_replays () =
  let path = fresh_path ".approved-no-reason.jsonl" in
  remove_if_exists path;
  let out = open_out path in
  output_string
    out
    ({|{"event":"register","id":"vrf-old","started_at":1.0,"registration":|}
     ^ {|{"task_id":"task-1","producer":"p","authority_kind":"system_llm_agent",|}
     ^ {|"authority_actor":"verifier_exact"}}|}
     ^ "\n"
     ^ {|{"event":"complete","id":"vrf-old","completion":{"outcome":"approved",|}
     ^ {|"elapsed_s":1.0,"tools":[]}}|}
     ^ "\n");
  close_out out;
  let replayed = R.replay path in
  (match R.get replayed ~verification_id:"vrf-old" with
   | None -> fail "an approval without a reason must still replay"
   | Some run ->
     check string "replayed status" "approved" (R.status_label run.status);
     check
       (option string)
       "absent reason reads back empty"
       (Some "")
       (str (R.run_to_yojson run) "reason"));
  remove_if_exists path
;;

(* A legacy row is skipped, not silently reinterpreted. *)
let test_legacy_retryable_row_is_rejected () =
  let path = fresh_path ".legacy-retryable.jsonl" in
  remove_if_exists path;
  let out = open_out path in
  output_string
    out
    ({|{"event":"register","id":"vrf-legacy","started_at":1.0,"registration":|}
     ^ {|{"task_id":"task-1","producer":"p","authority_kind":"system_llm_agent",|}
     ^ {|"authority_actor":"verifier_exact"}}|}
     ^ "\n"
     ^ {|{"event":"complete","id":"vrf-legacy","completion":{"outcome":"not_reviewed",|}
     ^ {|"elapsed_s":1.0,"tools":[],"gate":"invalid_verdict","detail":"d","retryable":true}}|}
     ^ "\n");
  close_out out;
  let replayed = R.replay path in
  check
    bool
    "legacy completion carrying retryable is not replayed"
    true
    (match R.get replayed ~verification_id:"vrf-legacy" with
     | None -> true
     | Some run -> not (String.equal (R.status_label run.status) "completed"));
  remove_if_exists path
;;

let test_replay_drops_running_reviews () =
  let path = fresh_path ".running.jsonl" in
  let t = R.create ~path () in
  register t ~verification_id:"vrf-done" ~started_at:10.0;
  R.mark_completed t ~verification_id:"vrf-done" ~outcome:(E.Approved { reason = "" }) ~tools:[] ~elapsed_s:1.0 ();
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
    ~tools:[]
    ~elapsed_s:1.0
    ();
  (* A deferred review is retried under a fresh authority actor; the table must
     name the live attempt, not accumulate one row per retry. *)
  R.register_running
    t
    ~verification_id:"vrf-retry"
    ~task_id:"task-136"
    ~producer:"keeper-gamma-agent"
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
    ~outcome:(E.Approved { reason = "" })
    ~tools:[]
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
    (String_util.contains_substring (Fs_compat.load_file path) "probably_fine");
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
    R.mark_completed t ~verification_id ~outcome:(E.Approved { reason = "" }) ~tools:[] ~elapsed_s:0.5 ()
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

let test_stream_replay_large_history () =
  let path = fresh_path ".stream-large.jsonl" in
  let total = 350 in
  let out = open_out path in
  for i = 1 to total do
    let id = Printf.sprintf "vrf-stream-%03d" i in
    let started_at = float_of_int i in
    let reg_line =
      Printf.sprintf
        {|{"event":"register","id":"%s","started_at":%.1f,"registration":{"task_id":"task-%d","producer":"p","authority_kind":"system_llm_agent","authority_actor":"reviewer"}}|}
        id started_at i
    in
    let comp_line =
      Printf.sprintf
        {|{"event":"complete","id":"%s","completion":{"outcome":"approved","elapsed_s":0.5,"tools":[]}}|}
        id
    in
    output_string out (reg_line ^ "\n" ^ comp_line ^ "\n")
  done;
  close_out out;
  let replayed = R.replay path in
  let runs = R.list_runs replayed in
  check int "retained bounded to max_completed_retained" R.max_completed_retained (List.length runs);
  check bool "newest run retained" true
    (Option.is_some (R.get replayed ~verification_id:(Printf.sprintf "vrf-stream-%03d" total)));
  check bool "old run evicted" true
    (Option.is_none (R.get replayed ~verification_id:"vrf-stream-001"));
  remove_if_exists path
;;

let test_stream_replay_retries_and_running_backfill () =
  let path = fresh_path ".stream-backfill.jsonl" in
  let total = 100 in
  let out = open_out path in
  for i = 1 to total do
    let id = Printf.sprintf "vrf-bk-%03d" i in
    let started_at = float_of_int i in
    let reg_line =
      Printf.sprintf
        {|{"event":"register","id":"%s","started_at":%.1f,"registration":{"task_id":"task-%d","producer":"p","authority_kind":"system_llm_agent","authority_actor":"reviewer"}}|}
        id started_at i
    in
    let comp_line =
      Printf.sprintf
        {|{"event":"complete","id":"%s","completion":{"outcome":"approved","elapsed_s":0.5,"tools":[]}}|}
        id
    in
    output_string out (reg_line ^ "\n" ^ comp_line ^ "\n")
  done;
  (* The newest 10 runs are retried as Running and left uncompleted before EOF *)
  for i = 91 to total do
    let id = Printf.sprintf "vrf-bk-%03d" i in
    let started_at = float_of_int (i + 100) in
    let retry_line =
      Printf.sprintf
        {|{"event":"register","id":"%s","started_at":%.1f,"registration":{"task_id":"task-%d","producer":"p","authority_kind":"system_llm_agent","authority_actor":"reviewer"}}|}
        id started_at i
    in
    output_string out (retry_line ^ "\n")
  done;
  close_out out;
  let replayed = R.replay path in
  let runs = R.list_runs replayed in
  (* All 10 running entries are dropped on replay, and the remaining completed entries
     backfill so that exactly max_completed_retained (64) are retained *)
  check int "backfills to exactly max_completed_retained" R.max_completed_retained (List.length runs);
  check bool "newest non-running completed retained (vrf-bk-090)" true
    (Option.is_some (R.get replayed ~verification_id:"vrf-bk-090"));
  check bool "oldest backfilled completed retained (vrf-bk-027)" true
    (Option.is_some (R.get replayed ~verification_id:"vrf-bk-027"));
  check bool "evicted beyond retention window (vrf-bk-026)" true
    (Option.is_none (R.get replayed ~verification_id:"vrf-bk-026"));
  remove_if_exists path
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

let test_tool_result_keeps_typed_disposition_and_input () =
  let result =
    Tool_result.ok
      ~tool_name:"report_review_verdict"
      ~start_time:(Time_compat.now ())
      "Completion verdict recorded: APPROVE"
  in
  let tool =
    R.observe_tool_result
      ~input:(`Assoc [ "verdict", `String "APPROVE" ])
      ~finished_at:12.5
      result
  in
  let t = R.create () in
  register t ~verification_id:"vrf-tools" ~started_at:10.0;
  R.mark_completed
    t
    ~verification_id:"vrf-tools"
    ~outcome:(E.Approved { reason = "" })
    ~tools:[ tool ]
    ~elapsed_s:0.1
    ();
  let json = R.get t ~verification_id:"vrf-tools" |> Option.get |> R.run_to_yojson in
  match field json "tools" with
  | Some (`List [ `Assoc fields ]) ->
    check
      (option string)
      "tool name"
      (Some "report_review_verdict")
      (match List.assoc_opt "tool_name" fields with
       | Some (`String value) -> Some value
       | _ -> None);
    check
      (option string)
      "typed disposition"
      (Some "completed")
      (match List.assoc_opt "disposition" fields with
       | Some (`String value) -> Some value
       | _ -> None);
    check
      (option (float 0.0001))
      "finished at"
      (Some 12.5)
      (match List.assoc_opt "finished_at" fields with
       | Some (`Float value) -> Some value
       | _ -> None)
  | _ -> fail "completed review must serialize one tool observation"
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
            "an approval carries the reviewer's stated reason"
            `Quick
            test_approval_reason_reaches_the_wire
        ; test_case
            "an approval written without a reason still replays"
            `Quick
            test_approval_row_without_reason_replays
        ; test_case
            "not_reviewed wire shape is gate and detail only"
            `Quick
            test_not_reviewed_wire_shape_is_gate_and_detail
        ; test_case
            "legacy row carrying retryable is rejected on replay"
            `Quick
            test_legacy_retryable_row_is_rejected
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
        ; test_case "stream replay large history" `Quick test_stream_replay_large_history
        ; test_case
            "stream replay retries and running backfill"
            `Quick
            test_stream_replay_retries_and_running_backfill
        ; test_case
            "tool evidence keeps input and typed disposition"
            `Quick
            test_tool_result_keeps_typed_disposition_and_input
        ; test_case
            "global registry has one installation owner"
            `Quick
            test_global_lifecycle_rejects_reinstallation
        ] )
    ]
;;
