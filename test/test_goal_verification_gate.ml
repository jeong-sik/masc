(** RFC-0387 — B1 creation requirement + verification ledger + the stage-2
    completion gate.

    B1: creation without a declared success condition ([metric] +
    [target_value]) is a typed rejection; updates of an existing row are not
    gated.

    Ledger: verdict commits round-trip through the file store, the decoders
    are strict (unknown fields / unknown variants are decode errors), a store
    that does not decode refuses every mutation AND fails every read loudly —
    never a silent "not verified yet".

    Stage 2 gate: [request_complete] moves Executing -> Verifying and persists
    the durable proof request BEFORE the phase write. Public MCP callers cannot
    name verifier commits. Only the application-owned typed verifier boundary
    can prove/refute completion, with non-blank
    evidence and fixed [verifier_exact] authority. A repeated
    [request_complete] on Verifying answers [Already], wakes an existing
    pending proof again, and re-arms the request when the ledger lost it (the
    P0-2 wedge). The FSM is the only transition decider; the ledger records. *)

open Alcotest
open Masc
open Workspace_types

(* The keeper.world frame prose this suite asserts ("증명 대기 중" in the
   Active Goals rows) moved out of the .ml sources into
   config/prompts/keeper.world.*.md group files, rendered through the prompt
   registry at assembly time. This executable never pinned a markdown dir,
   so prompt resolution depended on whatever the host/dune context happened
   to expose — green on developer machines, bare-data fallbacks inside the
   CI dune sandbox. Pin resolution to the repo's own prompt files — the same
   idiom test_tool_task_coverage uses; that executable passes inside the CI
   sandbox, so the mechanism is CI-proven. *)
let has_prompt_root path =
  Sys.file_exists (Filename.concat path "config/prompts/keeper.world.frame.md")
;;

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_prompt_root root -> root
  | _ ->
    let rec ascend path =
      if has_prompt_root path
      then path
      else (
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent)
    in
    ascend (Sys.getcwd ())
;;

let () =
  Prompt_registry.set_markdown_dir (Filename.concat (repo_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let temp_dir () =
  let path = Filename.temp_file "goal_verification_gate_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       f config)
;;

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let dispatch ctx ~name args =
  match Tool_workspace.dispatch ctx ~name ~args:(`Assoc args) with
  | Some result -> result
  | None -> fail (name ^ " not handled")
;;

let body_of result = Yojson.Safe.from_string (Tool_result.message result)

let must_succeed label result =
  if Tool_result.is_success result
  then body_of result
  else fail (Printf.sprintf "%s: expected success, got %s" label
               (Tool_result.message result))
;;

let must_fail label result =
  if Tool_result.is_success result
  then fail (Printf.sprintf "%s: expected rejection, got success" label)
  else body_of result
;;

let json_state json path =
  List.fold_left
    (fun acc key -> Yojson.Safe.Util.member key acc)
    json path
  |> Yojson.Safe.Util.to_string
;;

let json_bool json path =
  List.fold_left
    (fun acc key -> Yojson.Safe.Util.member key acc)
    json path
  |> Yojson.Safe.Util.to_bool
;;

let verdict ?(evidence = "observed by the verifier") outcome : Goal_verification.verdict =
  { Goal_verification.outcome
  ; verification_run_id = "goal-verifier-test-run"
  ; authority = Masc_domain.System_llm_agent { agent_run_id = "test-verifier" }
  ; evidence
  ; recorded_at = Masc_domain.now_iso ()
  }
;;

(* Poison the authoritative store AND its recovery mirror; the fail-closed
   rule mirrors Goal_store: no mutation may proceed on a store that did not
   decode. (Poisoning the primary alone recovers from the mirror — that is
   what the mirror is for.) *)
let poison_ledger config =
  let poison path =
    Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc "not json")
  in
  let primary = Goal_verification.verifications_path config in
  poison primary;
  poison (primary ^ ".last-good")
;;

(* B1 *)

let test_create_requires_a_success_condition () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let rejected =
    must_fail
      "create without metric"
      (dispatch ctx ~name:"masc_goal_upsert" [ "title", `String "No condition" ])
  in
  check string "typed validation error" "validation_error"
    (json_state rejected [ "error_code" ]);
  check bool "the message names the missing condition" true
    (String_util.contains_substring
       (Yojson.Safe.to_string rejected)
       "metric and target_value");
  (* A blank value rejects exactly like an absent one. *)
  let blank =
    must_fail
      "create with blank target_value"
      (dispatch
         ctx
         ~name:"masc_goal_upsert"
         [ "title", `String "Blank condition"
         ; "metric", `String "verified services"
         ; "target_value", `String "   "
         ])
  in
  check string "typed validation error" "validation_error"
    (json_state blank [ "error_code" ])
;;

let test_create_with_a_success_condition_succeeds () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let body =
    must_succeed
      "create with a success condition"
      (dispatch
         ctx
         ~name:"masc_goal_upsert"
         [ "title", `String "Verifiable goal"
         ; "metric", `String "verified services"
         ; "target_value", `String "3"
         ])
  in
  check string "created" "created" (json_state body [ "action" ])
;;

let test_update_is_not_gated_by_b1 () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal
        config
        ~title:"Created with a condition"
        ~metric:"m"
        ~target_value:"1"
        ()
    with
    | Ok payload -> payload
    | Error msg -> fail msg
  in
  (* B1 gates creation only: updating an existing row without re-stating the
     success condition is metadata maintenance, not a new declaration. *)
  match
    Goal_store.upsert_goal config ~id:goal.id ~title:"Renamed" ()
  with
  | Ok (_, `updated) -> ()
  | Ok (_, `created) -> fail "an existing id must update, not create"
  | Error msg -> fail ("ungated update rejected: " ^ msg)
;;

let test_undecodable_goal_store_reports_corruption_not_b1 () =
  with_workspace
  @@ fun config ->
  (* Poison the GOAL store: the create/update split is decided inside the
     write lock on the decoded state, so a corrupt store must surface the
     fail-closed persistence error — not "metric and target_value are
     required", which would misreport corruption as a caller mistake. *)
  let goals_path = Goal_store.goals_path config in
  let poison path =
    Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc "not json")
  in
  poison goals_path;
  poison (goals_path ^ ".last-good");
  match Goal_store.upsert_goal config ~title:"x" ~metric:"m" ~target_value:"1" () with
  | Ok _ -> fail "upsert_goal wrote over an undecodable store"
  | Error msg ->
    check bool "fail-closed persistence error, not the B1 message" true
      (String_util.contains_substring msg "did not decode");
    check bool "must not read as the B1 rejection" false
      (String_util.contains_substring msg "metric and target_value")
;;

(* Ledger: record/read round-trip *)

(* Ledger: record-only discipline (stage 1 pins the preconditions the stage-2
   gate relies on) *)

let test_proof_verdict_requires_a_pending_request () =
  with_workspace
  @@ fun config ->
  match
    Goal_verification.record_proof_verdict
      config
      ~goal_id:"goal-no-request"
      (verdict Goal_verification.Proven)
  with
  | Ok _ -> fail "proof verdict committed without a pending request"
  | Error msg ->
    check bool "the refusal names the missing request" true
      (String_util.contains_substring msg "no pending proof request")
;;

(* Ledger: strict decode, fail-closed mutations, fail-loud reads *)

let test_undecodable_ledger_fails_closed_and_loud () =
  with_workspace
  @@ fun config ->
  ignore
    (match
       Goal_verification.mark_proof_pending config ~goal_id:"goal-corrupt"
     with
     | Ok _ -> ()
     | Error msg -> fail msg);
  poison_ledger config;
  (* Mutations refuse. *)
  (match
     Goal_verification.mark_proof_pending config ~goal_id:"goal-corrupt"
   with
   | Ok _ -> fail "mutation proceeded on an undecodable ledger"
   | Error _ -> ());
  (* Reads fail LOUD: an undecodable ledger is an Error, never [None] — a
     corrupt store must not render as "not verified yet". *)
  (match Goal_verification.get_record config ~goal_id:"goal-corrupt" with
   | Ok _ -> fail "lenient read disguised a corrupt ledger as absence"
   | Error msg ->
     check bool "the decode failure is named" true
       (String_util.contains_substring msg "did not decode"));
  match Goal_verification.load_records config with
  | Ok _ -> fail "bulk read disguised a corrupt ledger"
  | Error msg ->
    check bool "the decode failure is named" true
      (String_util.contains_substring msg "did not decode")
;;

let test_unknown_ledger_field_is_a_decode_error () =
  with_workspace
  @@ fun config ->
  ignore
    (match
       Goal_verification.mark_proof_pending config ~goal_id:"goal-strict"
     with
     | Ok _ -> ()
     | Error msg -> fail msg);
  (* Hand-edit the committed store: add an unknown field to the one row. *)
  let path = Goal_verification.verifications_path config in
  let json = Yojson.Safe.from_file path in
  let poisoned =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             match key, value with
             | "records", `List [ `Assoc row ] ->
               ( "records"
               , `List [ `Assoc (("surprise_field", `Bool true) :: row) ] )
             | _ -> key, value)
           fields)
    | _ -> fail "unexpected ledger shape"
  in
  Yojson.Safe.to_file path poisoned;
  Yojson.Safe.to_file (path ^ ".last-good") poisoned;
  match Goal_verification.get_record config ~goal_id:"goal-strict" with
  | Ok _ -> fail "an unknown field decoded silently"
  | Error msg ->
    check bool "the unknown field is named" true
      (String_util.contains_substring msg "surprise_field")
;;

let test_retired_human_confirmation_state_is_a_decode_error () =
  with_workspace
  @@ fun config ->
  (match Goal_verification.mark_proof_pending config ~goal_id:"goal-no-human-legacy" with
   | Ok _ -> ()
   | Error msg -> fail msg);
  let path = Goal_verification.verifications_path config in
  let json = Yojson.Safe.from_file path in
  let poisoned =
    match json with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              match key, value with
              | "records", `List [ `Assoc row ] ->
                let row =
                  List.map
                    (fun (field, value) ->
                       if String.equal field "completion"
                       then field, `Assoc [ "state", `String "human_confirmed" ]
                       else field, value)
                    row
                in
                key, `List [ `Assoc row ]
              | _ -> key, value)
           fields)
    | _ -> fail "unexpected ledger shape"
  in
  Yojson.Safe.to_file path poisoned;
  Yojson.Safe.to_file (path ^ ".last-good") poisoned;
  match Goal_verification.get_record config ~goal_id:"goal-no-human-legacy" with
  | Ok _ -> fail "retired human confirmation state decoded silently"
  | Error msg ->
    check bool "the retired state is rejected as unknown" true
      (String_util.contains_substring msg "human_confirmed")
;;

(* Observability: the read surfaces join the ledger *)

let test_goal_list_joins_the_ledger () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let created =
    must_succeed
      "create goal"
      (dispatch
         ctx
         ~name:"masc_goal_upsert"
         [ "title", `String "Observable goal"
         ; "metric", `String "verified services"
         ; "target_value", `String "3"
         ])
  in
  let goal_id = json_state created [ "goal_id" ] in
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" []) in
  let goals = Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list in
  (match goals with
   | [ goal_json ] ->
     check string "completion renders idle" "idle"
       (json_state goal_json [ "verification"; "completion"; "state" ])
   | _ -> fail "expected one listed goal");
  (* A durable request shows up in the same join. *)
  ignore
    (match Goal_verification.mark_proof_pending config ~goal_id with
     | Ok _ -> ()
     | Error msg -> fail msg);
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" []) in
  let goals = Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list in
  match goals with
  | [ goal_json ] ->
    check string "the request is observable" "proof_pending"
      (json_state goal_json [ "verification"; "completion"; "state" ])
  | _ -> fail "expected one listed goal"
;;

let test_goal_list_renders_a_ledger_error_state () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  ignore
    (must_succeed
       "create goal"
       (dispatch
          ctx
          ~name:"masc_goal_upsert"
          [ "title", `String "Goal beside a corrupt ledger"
          ; "metric", `String "m"
          ; "target_value", `String "1"
          ]));
  poison_ledger config;
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" []) in
  let goals = Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list in
  match goals with
  | [ goal_json ] ->
    check string "corruption renders as ledger_error, not as the default"
      "ledger_error"
      (json_state goal_json [ "verification"; "state" ])
  | _ -> fail "expected one listed goal"
;;

(* {1 Stage 2 — the completion gate (RFC-0387 §3.2/§3.3/§4/§5)} *)

let create_goal ctx title =
  let created =
    must_succeed
      "create goal"
      (dispatch
         ctx
         ~name:"masc_goal_upsert"
         [ "title", `String title
         ; "metric", `String "m"
         ; "target_value", `String "1"
         ])
  in
  json_state created [ "goal_id" ]
;;

let transition ctx goal_id ?note ?evidence action =
  let args =
    [ "goal_id", `String goal_id; "action", `String action ]
    @ (match note with
       | Some note -> [ "note", `String note ]
       | None -> [])
    @ (match evidence with
       | Some evidence -> [ "evidence", `String evidence ]
       | None -> [])
  in
  dispatch ctx ~name:"masc_goal_transition" args
;;

let verifier_transition config goal_id decision evidence =
  Workspace_goals.commit_verifier_decision
    ~tool_name:"goal_verifier_commit"
    ~start_time:0.
    config
    ~goal_id
    ~verification_run_id:"goal-verifier-test-run"
    ~decision
    ~evidence
;;

let stored_phase config goal_id =
  match Goal_store.get_goal config ~goal_id with
  | Some goal -> Goal_phase.to_string goal.Goal_store.phase
  | None -> fail ("goal not found: " ^ goal_id)
;;

let ledger_record config goal_id =
  match Goal_verification.get_record config ~goal_id with
  | Ok (Some record) -> record
  | Ok None -> fail ("no ledger row for " ^ goal_id)
  | Error msg -> fail msg
;;

let goal_events_text config =
  let path =
    Filename.concat
      (Filename.dirname (Goal_verification.verifications_path config))
      "goal_events.jsonl"
  in
  if Sys.file_exists path
  then (
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let b = Buffer.create 256 in
         (try
            while true do
              Buffer.add_string b (input_line ic);
              Buffer.add_char b '\n'
            done
          with
          | End_of_file -> ());
         Buffer.contents b))
  else ""
;;

(* (a) The completion request enters the gate; the durable proof request is
   visible in the response and in the ledger. *)
let test_request_complete_enters_verifying_with_proof_pending () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Gated completion" in
  let entered =
    must_succeed "request_complete" (transition ctx goal_id "request_complete")
  in
  check string "phase moved to verifying" "verifying"
    (json_state entered [ "goal"; "phase" ]);
  check string "the request is persisted before the phase" "proof_pending"
    (json_state entered [ "verification"; "completion"; "state" ]);
  check string "the store agrees" "verifying" (stored_phase config goal_id);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_pending _ -> ()
   | _ -> fail "ledger must hold the durable proof request")
;;

(* (b) Public callers cannot self-verify. Only the typed verifier boundary can
   complete the goal, with mandatory evidence and fixed authority. *)
let test_proof_proven_completes_with_authority_and_evidence () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Proof-gated goal" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let public_refusal =
    must_fail "public record_proof_proven"
      (transition
         ctx
         goal_id
         ~evidence:"caller-provided evidence"
         "record_proof_proven")
  in
  check string "verifier action is not in the public enum" "validation_error"
    (json_state public_refusal [ "error_code" ]);
  let blank =
    must_fail "typed proof verdict with blank evidence"
      (verifier_transition config goal_id Workspace_goals.Proof_proven "   ")
  in
  check string "typed validation error" "validation_error"
    (json_state blank [ "error_code" ]);
  check string "a refused verdict does not move the phase" "verifying"
    (stored_phase config goal_id);
  let unbound_attempt =
    must_fail "typed proof verdict with blank run ID"
      (Workspace_goals.commit_verifier_decision
         ~tool_name:"goal_verifier_commit"
         ~start_time:0.
         config
         ~goal_id
         ~verification_run_id:"   "
         ~decision:Workspace_goals.Proof_proven
         ~evidence:"metric observed at target")
  in
  check string "blank run ID is a typed validation error" "validation_error"
    (json_state unbound_attempt [ "error_code" ]);
  check string "an unbound verdict does not move the phase" "verifying"
    (stored_phase config goal_id);
  let completed =
    must_succeed "typed proof proven"
      (verifier_transition
         config
         goal_id
         Workspace_goals.Proof_proven
         "metric observed at target")
  in
  check string "completed via proof" "completed"
    (json_state completed [ "goal"; "phase" ]);
  check string "ledger shows the proven verdict" "proof_proven"
    (json_state completed [ "verification"; "completion"; "state" ]);
  check string "the evidence is on the verdict" "metric observed at target"
    (json_state completed [ "verification"; "completion"; "verdict"; "evidence" ]);
  check string "the verdict retains its exact verifier attempt"
    "goal-verifier-test-run"
    (json_state
       completed
       [ "verification"; "completion"; "verdict"; "verification_run_id" ]);
  check string "the caller cannot impersonate the typed authority" "verifier_exact"
    (json_state
       completed
       [ "verification"; "completion"; "verdict"; "authority"; "actor" ]);
  check string "authority kind is the system-llm slot" "system_llm_agent"
    (json_state
       completed
       [ "verification"; "completion"; "verdict"; "authority"; "kind" ])
;;

(* (c) A refuted proof returns the goal to Executing; the reason survives in
   the ledger and in goal_events.jsonl. *)
let test_proof_refuted_returns_to_executing_with_reason () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Refutable goal" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let refuted =
    must_succeed "typed proof refuted"
      (verifier_transition
         config
         goal_id
         (Workspace_goals.Proof_refuted { reason = "metric moved under the claim" })
         "coverage run attached")
  in
  check string "back to executing" "executing"
    (json_state refuted [ "goal"; "phase" ]);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_refuted
       { outcome = Goal_verification.Refuted { reason }; _ } ->
     check string "the refutation reason is preserved"
       "metric moved under the claim" reason
   | _ -> fail "ledger must hold the refuted verdict");
  let events = goal_events_text config in
  check bool "the refutation reason reaches goal_events.jsonl" true
    (String_util.contains_substring events "metric moved under the claim");
  check bool "the event names the outcome" true
    (String_util.contains_substring events "refuted");
  (* Failure keeps its evidence but does not wedge the goal: the next request
     supersedes the refuted verdict and re-enters the gate. *)
  let reentered =
    must_succeed "request_complete again"
      (transition ctx goal_id "request_complete")
  in
  check string "re-request re-enters verifying" "verifying"
    (json_state reentered [ "goal"; "phase" ]);
  check string "a fresh proof request supersedes the refutation"
    "proof_pending"
    (json_state reentered [ "verification"; "completion"; "state" ])
;;

(* (d) The P0-2 wedge — phase=Verifying with the ledger at Completion_idle —
   is re-armed by the repeated request_complete: the FSM answers [Already]
   and the handler re-writes the durable request before answering. *)
let test_verifying_repeat_rearms_a_missing_proof_request () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Wedged goal" in
  (* Simulate the crash window: the phase is Verifying but the ledger never
     recorded the proof request. *)
  (match
     Goal_store.upsert_goal config ~id:goal_id ~phase:Goal_phase.Verifying ()
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  (* Creation writes no ledger row, so the wedge starts with none at all —
     the same hole the handler re-arms, reached without a row to empty. *)
  (match Goal_verification.get_record config ~goal_id with
   | Ok None -> ()
   | Ok (Some _) -> fail "test setup: the wedge needs no durable request"
   | Error msg -> fail msg);
  let answered =
    must_succeed "repeated request_complete"
      (transition ctx goal_id "request_complete")
  in
  check bool "answered as Already (noop)" true
    (json_bool answered [ "noop" ]);
  check string "still verifying" "verifying" (json_state answered [ "phase" ]);
  check string "the proof request is re-armed" "proof_pending"
    (json_state answered [ "verification"; "completion"; "state" ]);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_pending _ -> ()
   | _ -> fail "the re-arm must be durable, not just reported");
  (* And the gate drains from there. *)
  let completed =
    must_succeed "typed proof proven"
      (verifier_transition
         config
         goal_id
         Workspace_goals.Proof_proven
         "verified after re-arm")
  in
  check string "the re-armed gate completes" "completed"
    (json_state completed [ "goal"; "phase" ])
;;

let test_verifying_repeat_wakes_an_existing_proof_request () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Deferred proof needs an explicit wake" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_pending _ -> ()
   | _ -> fail "test setup: the proof request must already be pending");
  let previous = Atomic.get Workspace_hooks.goal_verification_pending_fn in
  let wakes = ref [] in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.goal_verification_pending_fn previous)
    (fun () ->
       Atomic.set
         Workspace_hooks.goal_verification_pending_fn
         (fun _config ~goal_id -> wakes := goal_id :: !wakes);
       let answered =
         must_succeed "repeat request_complete"
           (transition ctx goal_id "request_complete")
       in
       check bool "the public transition remains idempotent" true
         (json_bool answered [ "noop" ]);
       check (list string) "the pending proof is explicitly woken once"
         [ goal_id ] (List.rev !wakes);
       check string "the goal remains verifying" "verifying"
         (json_state answered [ "phase" ]);
       check string "the durable request remains pending" "proof_pending"
         (json_state answered [ "verification"; "completion"; "state" ]))
;;

let test_verifying_repeat_reconciles_a_committed_proof () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Proof committed before crash" in
  ignore
    (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  (match
     Goal_verification.record_proof_verdict
       config
       ~goal_id
       (verdict ~evidence:"artifact inspected before crash" Goal_verification.Proven)
   with
   | Ok _ -> ()
   | Error msg -> fail msg);
  check string "phase write is the simulated missing effect" "verifying"
    (stored_phase config goal_id);
  let answered =
    must_succeed "repeated request reconciles proof"
      (transition ctx goal_id "request_complete")
  in
  check bool "response exposes recovery" true
    (json_bool answered [ "reconciled" ]);
  check string "the committed proof converges to completed" "completed"
    (json_state answered [ "goal"; "phase" ]);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven proof ->
    check string "recovery preserves the original proof run"
      "goal-verifier-test-run" proof.verification_run_id
  | _ -> fail "recovery rewrote the committed proof"
;;

(* (g) A keeper holding a Verifying goal keeps seeing it: the runtime-contract
   cross-check keeps it, the world observation keeps it, and the prompt names
   it with the proof-pending annotation (P0-1). *)
let test_keeper_keeps_and_sees_a_verifying_goal () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Goal under proof" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String "gate-keeper"
           ; "trace_id", `String "gate-keeper-trace"
           ])
    with
    | Ok meta -> meta
    | Error e -> fail ("meta_of_json_fixture: " ^ e)
  in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
  in
  check
    (list string)
    "the world observation keeps the verifying goal"
    [ goal_id ]
    observation.Keeper_world_observation.active_goals;
  (* The subject here is how a [Verifying] goal renders, not which goals a
     turn is given: the summary is stated so the annotation is what the check
     depends on. *)
  let summaries =
    [ { Keeper_unified_prompt.summary_goal_id = goal_id
      ; summary_title = "Goal under proof"
      ; summary_phase = Some Goal_phase.Verifying
      }
    ]
  in
  let { Keeper_unified_prompt.world_state; _ } =
    Keeper_unified_prompt.build_prompt
      ~meta
      ~config
      ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~active_goal_summaries:summaries
      ~observation
      ()
  in
  check bool "the Active Goals block names the goal" true
    (String_util.contains_substring world_state goal_id);
  check bool "with the proof-pending annotation" true
    (String_util.contains_substring world_state "증명 대기 중")
;;

(* (h) A corrupt ledger during request_complete is a typed error, never a
   silent pass — and the phase does not move. *)
let test_corrupt_ledger_fails_request_complete_loudly () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Goal beside a poisoned ledger" in
  poison_ledger config;
  let refused =
    must_fail "request_complete over a corrupt ledger"
      (transition ctx goal_id "request_complete")
  in
  check bool "the decode failure is named" true
    (String_util.contains_substring
       (Yojson.Safe.to_string refused)
       "did not decode");
  check string "the phase did not move" "executing"
    (stored_phase config goal_id)
;;

let () =
  run
    "goal_verification_gate"
    [ ( "b1 creation requirement"
      , [ test_case "creation requires a success condition" `Quick
            test_create_requires_a_success_condition
        ; test_case "creation with a success condition succeeds" `Quick
            test_create_with_a_success_condition_succeeds
        ; test_case "update is not gated by B1" `Quick
            test_update_is_not_gated_by_b1
        ; test_case "undecodable goal store reports corruption, not B1" `Quick
            test_undecodable_goal_store_reports_corruption_not_b1
        ] )
    ; ( "ledger record-only discipline"
      , [ test_case "proof verdict requires a pending request" `Quick
            test_proof_verdict_requires_a_pending_request
        ] )
    ; ( "store discipline"
      , [ test_case "undecodable ledger fails closed and loud" `Quick
            test_undecodable_ledger_fails_closed_and_loud
        ; test_case "unknown ledger field is a decode error" `Quick
            test_unknown_ledger_field_is_a_decode_error
        ; test_case "retired human confirmation state is a decode error" `Quick
            test_retired_human_confirmation_state_is_a_decode_error
        ] )
    ; ( "observability"
      , [ test_case "goal list joins the ledger" `Quick
            test_goal_list_joins_the_ledger
        ; test_case "goal list renders a ledger-error state" `Quick
            test_goal_list_renders_a_ledger_error_state
        ] )
    ; ( "stage 2 gate"
      , [ test_case "request_complete enters verifying with proof pending" `Quick
            test_request_complete_enters_verifying_with_proof_pending
        ; test_case "proof proven completes with authority and evidence" `Quick
            test_proof_proven_completes_with_authority_and_evidence
        ; test_case "proof refuted returns to executing with reason" `Quick
            test_proof_refuted_returns_to_executing_with_reason
        ; test_case "verifying repeat re-arms a missing proof request" `Quick
            test_verifying_repeat_rearms_a_missing_proof_request
        ; test_case "verifying repeat wakes an existing proof request" `Quick
            test_verifying_repeat_wakes_an_existing_proof_request
        ; test_case "verifying repeat reconciles a committed proof" `Quick
            test_verifying_repeat_reconciles_a_committed_proof
        ; test_case "keeper keeps and sees a verifying goal" `Quick
            test_keeper_keeps_and_sees_a_verifying_goal
        ; test_case "corrupt ledger fails request_complete loudly" `Quick
            test_corrupt_ledger_fails_request_complete_loudly
        ] )
    ]
;;
