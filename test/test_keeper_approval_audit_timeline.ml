(** The approval audit log has one writer vocabulary and one reader.

    The reader — [Keeper_runtime_trust_timeline.approval_event_timeline_event],
    which renders each record into the operator's trust timeline — used to match
    the [event] field as a bare string. It carried arms for five spellings no
    writer emits ("expired", "approval_timeout", "cancelled",
    "auto_approved_rule_match", "auto_approved_always") and had no arm for ten
    that writers do emit, so those ten fell through a catch-all: a successful
    gate pass, a consumed grant and an unreadable rule store all reached the
    dashboard as an unlabelled warning with the raw string as their summary.

    [audit_event] closes the vocabulary, so the compiler now forces both ends to
    agree. These cases pin what that agreement renders — in particular that the
    success path and the failure path are no longer the same event. *)

module Q = Keeper_approval_queue_rules_types
module Audit = Keeper_approval.Audit
module Timeline = Masc.Keeper_runtime_trust_timeline
open Alcotest

(* Every constructor. [audit_event_to_string] is exhaustive, so a new one fails
   to compile there first; this list keeps the rendered values pinned. *)
let every_event =
  [ Audit.Pending
  ; Audit.Resolved
  ; Audit.Summary_updated
  ; Audit.Rule_created
  ; Audit.Rule_renewed
  ; Audit.Rule_deleted
  ; Audit.Grant_consumed
  ; Audit.Gate_allowed
  ; Audit.Gate_exact_rule_expired
  ; Audit.Gate_exact_rule_store_degraded
  ; Audit.Gate_grant_unavailable
  ; Audit.Auto_judge_operator_retry_started
  ; Audit.Auto_judge_block_observation_superseded
  ; Audit.Auto_judge_restart_worker_recovered
  ; Audit.Auto_judge_restart_judgment_recovered
  ]
;;

let audit_record ?decision_kind event =
  `Assoc
    ([ ("ts", `Float 1_700_000_000.0)
     ; ("event", `String (Audit.event_to_string event))
     ; ("id", `String "appr-1")
     ; ("keeper", `String "alpha")
     ; ("tool", `String "bash")
     ]
    @
    match decision_kind with
    | None -> []
    | Some kind -> [ ("decision_kind", `String (Audit.decision_kind_to_string kind)) ])
;;

let field key json =
  match json with
  | `Assoc fields -> (
    match List.assoc_opt key fields with
    | Some (`String value) -> Some value
    | _ -> None)
  | _ -> None
;;

let rendered ?decision_kind event =
  match Timeline.approval_event_timeline_event (audit_record ?decision_kind event) with
  | Some json -> json
  | None ->
    failf
      "no timeline event for %s; the reader dropped a record a writer emits"
      (Audit.event_to_string event)
;;

let test_round_trip () =
  List.iter
    (fun event ->
      let spelling = Audit.event_to_string event in
      check bool spelling true (Audit.event_of_string spelling = Some event))
    every_event
;;

(* The defect in one case: no writer's event may render through the
   unrecognized-spelling path. *)
let test_no_writer_event_is_unrecognized () =
  List.iter
    (fun event ->
      let spelling = Audit.event_to_string event in
      check
        (option bool)
        spelling
        (Some false)
        (Option.map
           (String.equal "approval_event_unrecognized")
           (field "kind" (rendered event))))
    every_event
;;

(* The dashboard drops any severity outside these three. *)
let test_severity_is_renderable () =
  List.iter
    (fun event ->
      let spelling = Audit.event_to_string event in
      match field "severity" (rendered event) with
      | Some ("ok" | "warn" | "bad") -> ()
      | other ->
        failf
          "%s: severity %s is not one the dashboard accepts"
          spelling
          (Option.value ~default:"<absent>" other))
    every_event
;;

(* A successful gate pass used to be indistinguishable from an unreadable rule
   store: both were "warn" titled "Approval · bash". *)
let test_success_and_failure_differ () =
  let allowed = rendered Audit.Gate_allowed in
  let degraded = rendered Audit.Gate_exact_rule_store_degraded in
  check (option string) "gate allow is ok" (Some "ok") (field "severity" allowed);
  check
    (option string)
    "unreadable rule store is bad"
    (Some "bad")
    (field "severity" degraded);
  check
    bool
    "the two carry different kinds"
    true
    (field "kind" allowed <> field "kind" degraded)
;;

let test_consumed_grant_is_not_a_warning () =
  check
    (option string)
    "grant consumed"
    (Some "ok")
    (field "severity" (rendered Audit.Grant_consumed))
;;

(* Resolution severity comes off the decision_kind field the writer records, not
   off a substring scan of the rendered decision text. *)
let test_resolution_reads_the_decision_kind () =
  check
    (option string)
    "reject"
    (Some "bad")
    (field "severity" (rendered ~decision_kind:Audit.Decision_reject Audit.Resolved));
  check
    (option string)
    "approve"
    (Some "ok")
    (field "severity" (rendered ~decision_kind:Audit.Decision_approve Audit.Resolved))
;;

(* The old reader scanned the rendered decision for "reject", so an approval
   whose text merely mentioned the word was reported as a rejection. *)
let test_approval_mentioning_rejection_is_not_bad () =
  let json =
    `Assoc
      [ ("ts", `Float 1_700_000_000.0)
      ; ("event", `String (Audit.event_to_string Audit.Resolved))
      ; ("id", `String "appr-2")
      ; ("keeper", `String "alpha")
      ; ("tool", `String "bash")
      ; ("decision", `String "approve: proceed after the earlier reject")
      ; ("decision_kind", `String (Audit.decision_kind_to_string Audit.Decision_approve))
      ]
  in
  match Timeline.approval_event_timeline_event json with
  | None -> fail "resolved record produced no timeline event"
  | Some event -> check (option string) "severity" (Some "ok") (field "severity" event)
;;

(* Records on disk predate this build's vocabulary, so an unknown spelling has
   to render as exactly that rather than as a warning about the tool. *)
let test_unknown_spelling_says_so () =
  let json =
    `Assoc
      [ ("ts", `Float 1_700_000_000.0)
      ; ("event", `String "auto_approved_always")
      ; ("id", `String "appr-3")
      ; ("keeper", `String "alpha")
      ; ("tool", `String "bash")
      ]
  in
  match Timeline.approval_event_timeline_event json with
  | None -> fail "unknown spelling produced no timeline event"
  | Some event ->
    check
      (option string)
      "kind"
      (Some "approval_event_unrecognized")
      (field "kind" event);
    check (option string) "severity" (Some "warn") (field "severity" event)
;;

(* [decision_source] answers who decided; [authorization_source] answers under
   what standing authority. Collapsing the second into the first is not a
   cosmetic loss: over 2026-08-01..06 the Gate recorded 6,670 allows, every one
   of them decision_source=always_allowed, and the file could not say that 4,570
   came from the workspace being in Always_allow mode and 2,100 from a per-keeper
   blanket, while operator-approved exact rules accounted for none. *)
let every_authorization_source =
  [ Q.One_shot_resolution
  ; Q.Exact_always_rule
  ; Q.Keeper_always_allow
  ; Q.Workspace_always_allow
  ; Q.Readonly_sandbox
  ; Q.Local_output
  ; Q.Observed_in_box
  ]
;;

let test_authorization_sources_are_distinct () =
  let rendered = List.map Q.authorization_source_to_string every_authorization_source in
  check (list string) "each authority renders as itself"
    [ "one_shot_resolution"; "exact_always_rule"; "keeper_always_allow";
      "workspace_always_allow"; "readonly_sandbox"; "local_output";
      "observed_in_box" ]
    rendered;
  check int "no two authorities share a spelling"
    (List.length rendered)
    (List.length (List.sort_uniq String.compare rendered))
;;

let test_authorization_source_round_trips () =
  List.iter
    (fun source ->
      let spelling = Q.authorization_source_to_string source in
      check (option string) ("round-trips: " ^ spelling) (Some spelling)
        (Option.map Q.authorization_source_to_string
           (Q.authorization_source_of_string spelling)))
    every_authorization_source
;;

let test_unknown_authorization_source_is_none () =
  check bool "an unknown spelling is not coerced to a default" true
    (Option.is_none (Q.authorization_source_of_string "always_allowed"))
;;

let with_audit_workspace f =
  let base_path = Filename.temp_file "approval-owner-latest-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect
    ~finally:(fun () ->
      Audit.For_testing.reset_store ();
      Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let audit_location ~base_path =
  Dated_jsonl.Store.(at (root_of_base_path ~base_path) Root.Audit_approvals)
;;

let append_audit ~base_path ~keeper_name id =
  let receipt =
    Audit.record ~base_path ~event_type:Audit.Gate_allowed ~id ~keeper_name
      ~tool_name:"external-effect" ()
  in
  match receipt.write_result, receipt.cleanup_failure with
  | Ok (), None -> ()
  | Error _, _ | Ok (), Some _ -> fail "actual audit append did not settle cleanly"
;;

let recent_ids ~base_path ?keeper_name n =
  match Audit.read_recent ~base_path ?keeper_name ~n () with
  | Error error -> fail (Audit.read_error_to_string error)
  | Ok rows ->
    List.map
      (fun row ->
        match field "id" row with
        | Some id -> id
        | None -> fail "selected record has no ID")
      rows
;;

let test_sparse_owner_history () =
  with_audit_workspace @@ fun base_path ->
  append_audit ~base_path ~keeper_name:"target" "older";
  (* Move an actual writer-produced row to yesterday's canonical file so the
     lookup has to cross both a busy day and a physical day boundary. *)
  let location = audit_location ~base_path in
  let today = Dated_jsonl.Store.dated_path_now location in
  let yesterday =
    Dated_jsonl.Store.dated_path location ~ts:(Unix.gettimeofday () -. 86400.)
  in
  Fs_compat.mkdir_p (Filename.dirname yesterday.path);
  Sys.rename today.path yesterday.path;
  for idx = 1 to 650 do
    append_audit ~base_path ~keeper_name:"busy" (string_of_int idx)
  done;
  append_audit ~base_path ~keeper_name:"target" "newer";
  check (list string) "unrelated rows cannot hide older target"
    [ "newer"; "older" ] (recent_ids ~base_path ~keeper_name:"target" 2);
  append_audit ~base_path ~keeper_name:"target" "fresh";
  check (list string) "immediate append is visible without resetting store"
    [ "fresh"; "newer" ] (recent_ids ~base_path ~keeper_name:"target" 2);
  check (list string) "EOF returns every available target"
    [ "fresh"; "newer"; "older" ] (recent_ids ~base_path ~keeper_name:"target" 8);
  check (list string) "global latest preserves order"
    [ "fresh"; "newer"; "650" ] (recent_ids ~base_path 3);
  with_audit_workspace @@ fun other ->
  append_audit ~base_path:other ~keeper_name:"target" "other-workspace";
  check (list string) "same Keeper in another workspace stays separate"
    [ "other-workspace" ] (recent_ids ~base_path:other ~keeper_name:"target" 2);
  check (list string) "original workspace remains unchanged"
    [ "fresh"; "newer" ] (recent_ids ~base_path ~keeper_name:"target" 2)
;;

let append_raw_audit ~base_path line =
  let path = Dated_jsonl.Store.dated_path_now (audit_location ~base_path) in
  Fs_compat.mkdir_p (Filename.dirname path.path);
  let channel = open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o600 path.path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (line ^ "\n"))
;;

let expect_recent_error ~base_path =
  match Audit.read_recent ~base_path ~keeper_name:"target" ~n:2 () with
  | Ok _ -> fail "uncertain ownership or unreadable audit became an exact result"
  | Error error ->
    check bool "typed read stage" true (error.stage = Audit.Read_recent);
    check bool "error retains detail" true (String.length error.detail > 0)
;;

let test_scoped_corruption_boundary () =
  with_audit_workspace @@ fun base_path ->
  append_audit ~base_path ~keeper_name:"target" "older";
  append_raw_audit ~base_path "{broken";
  append_audit ~base_path ~keeper_name:"target" "newer";
  check (list string) "complete newest suffix does not visit older corruption"
    [ "newer" ] (recent_ids ~base_path ~keeper_name:"target" 1);
  expect_recent_error ~base_path
;;

let test_unidentified_owner_is_not_skipped () =
  List.iter
    (fun invalid ->
      with_audit_workspace @@ fun base_path ->
      append_audit ~base_path ~keeper_name:"target" "older";
      append_raw_audit ~base_path invalid;
      append_audit ~base_path ~keeper_name:"target" "newer";
      expect_recent_error ~base_path)
    [ "{}"; "{\"keeper\":3}";
      "{\"keeper\":\"busy\",\"keeper\":\"target\"}" ]
;;

let test_empty_and_unreadable_audit () =
  with_audit_workspace @@ fun base_path ->
  check (list string) "missing store is empty" []
    (recent_ids ~base_path ~keeper_name:"target" 2);
  let directory = Dated_jsonl.Store.dir (audit_location ~base_path) in
  (* Replace the empty store with a file: absence and invalid layout differ. *)
  if Sys.file_exists directory then Fs_compat.remove_tree directory;
  Fs_compat.mkdir_p (Filename.dirname directory);
  Out_channel.with_open_text directory (fun out -> output_string out "not a directory");
  expect_recent_error ~base_path;
  check (list string) "zero limit performs no I/O" []
    (recent_ids ~base_path ~keeper_name:"target" 0)
;;

let () =
  Alcotest.run
    "Keeper approval audit timeline"
    [ ( "exact owner history"
      , [ test_case "sparse history across days and fresh append" `Quick test_sparse_owner_history
        ; test_case "corruption is bounded by selected suffix" `Quick test_scoped_corruption_boundary
        ; test_case "unknown ownership is explicit" `Quick test_unidentified_owner_is_not_skipped
        ; test_case "absence differs from unreadable store" `Quick test_empty_and_unreadable_audit
        ] )
    ; ( "vocabulary"
      , [ test_case "every event round-trips" `Quick test_round_trip
        ; test_case
            "no writer event renders as unrecognized"
            `Quick
            test_no_writer_event_is_unrecognized
        ; test_case "severity is one the dashboard accepts" `Quick
            test_severity_is_renderable
        ] )
    ; ( "severity"
      , [ test_case "gate allow and degraded store differ" `Quick
            test_success_and_failure_differ
        ; test_case "a consumed grant is not a warning" `Quick
            test_consumed_grant_is_not_a_warning
        ; test_case "resolution reads decision_kind" `Quick
            test_resolution_reads_the_decision_kind
        ; test_case "an approval mentioning rejection stays ok" `Quick
            test_approval_mentioning_rejection_is_not_bad
        ] )
    ; ( "historical records"
      , [ test_case "an unknown spelling says so" `Quick test_unknown_spelling_says_so ] )
    ; ( "authorization source"
      , [ test_case "each authority renders distinctly" `Quick
            test_authorization_sources_are_distinct
        ; test_case "spellings round-trip" `Quick
            test_authorization_source_round_trips
        ; test_case "an unknown spelling is not coerced" `Quick
            test_unknown_authorization_source_is_none
        ] )
    ]
;;
