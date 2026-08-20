(** RFC-0387 stage 1 — B1 creation requirement + verification ledger
    (record-only evidence store) + its observability join.

    B1: creation without a declared success condition ([metric] +
    [target_value]) is a typed rejection; updates of an existing row are not
    gated.

    Ledger: verdict commits round-trip through the file store, the decoders
    are strict (unknown fields / unknown variants are decode errors), a store
    that does not decode refuses every mutation AND fails every read loudly —
    never a silent "not verified yet".

    Stage 1 has no lifecycle gate: [request_complete] still completes a Goal
    directly, and no caller writes the ledger. The gate phases/actions and
    the verifier caller are stage 2 (RFC-0387 §Staging). *)

open Alcotest
open Masc
open Workspace_types

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

let verdict ?(evidence = "observed by the verifier") outcome : Goal_verification.verdict =
  { Goal_verification.outcome
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

let test_criterion_verdict_round_trips () =
  with_workspace
  @@ fun config ->
  let committed =
    match
      Goal_verification.record_criterion_verdict
        config
        ~goal_id:"goal-roundtrip"
        (verdict Goal_verification.Proven)
    with
    | Ok record -> record
    | Error msg -> fail msg
  in
  (match committed.criterion with
   | Goal_verification.Criterion_viable _ -> ()
   | _ -> fail "proven verdict must land as Criterion_viable");
  (* A fresh read of the ledger agrees — the commit is durable. *)
  (match Goal_verification.get_record config ~goal_id:"goal-roundtrip" with
   | Ok (Some { criterion = Goal_verification.Criterion_viable _; _ }) -> ()
   | Ok (Some _) -> fail "round-trip changed the criterion state"
   | Ok None -> fail "committed record did not survive a fresh read"
   | Error msg -> fail msg);
  match Goal_verification.load_records config with
  | Error msg -> fail msg
  | Ok records ->
    check int "one row in the ledger" 1 (List.length records)
;;

let test_refuted_criterion_keeps_its_reason () =
  with_workspace
  @@ fun config ->
  match
    Goal_verification.record_criterion_verdict
      config
      ~goal_id:"goal-refuted"
      (verdict (Goal_verification.Refuted { reason = "no such API exists" }))
  with
  | Error msg -> fail msg
  | Ok _ ->
    (match Goal_verification.get_record config ~goal_id:"goal-refuted" with
     | Ok
         (Some
           { criterion =
               Goal_verification.Criterion_unreachable
                 { outcome = Goal_verification.Refuted { reason }; _ }
           ; _
           }) ->
       check string "the refutation reason is preserved" "no such API exists" reason
     | Ok (Some _) -> fail "refuted verdict must land as Criterion_unreachable"
     | Ok None -> fail "committed record did not survive a fresh read"
     | Error msg -> fail msg)
;;

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

let test_human_confirmation_requires_a_proven_proof () =
  with_workspace
  @@ fun config ->
  match
    Goal_verification.record_human_confirmation
      config
      ~goal_id:"goal-unproven"
      ~confirmed_by:"operator-test"
  with
  | Ok _ -> fail "human confirmation committed without a proven proof"
  | Error msg ->
    check bool "the refusal names the missing proof" true
      (String_util.contains_substring msg "needs a proven proof")
;;

(* Ledger: strict decode, fail-closed mutations, fail-loud reads *)

let test_undecodable_ledger_fails_closed_and_loud () =
  with_workspace
  @@ fun config ->
  ignore
    (match
       Goal_verification.record_criterion_verdict
         config
         ~goal_id:"goal-corrupt"
         (verdict Goal_verification.Proven)
     with
     | Ok _ -> ()
     | Error msg -> fail msg);
  poison_ledger config;
  (* Mutations refuse. *)
  (match
     Goal_verification.record_criterion_verdict
       config
       ~goal_id:"goal-corrupt"
       (verdict Goal_verification.Proven)
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
       Goal_verification.record_criterion_verdict
         config
         ~goal_id:"goal-strict"
         (verdict Goal_verification.Proven)
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
     (* No writer has run: the explicit pre-verification default renders. *)
     check string "criterion renders unchecked" "unchecked"
       (json_state goal_json [ "verification"; "criterion"; "state" ]);
     check string "completion renders idle" "idle"
       (json_state goal_json [ "verification"; "completion"; "state" ])
   | _ -> fail "expected one listed goal");
  (* A committed verdict shows up in the same join. *)
  ignore
    (match
       Goal_verification.record_criterion_verdict
         config
         ~goal_id
         (verdict Goal_verification.Proven)
     with
     | Ok _ -> ()
     | Error msg -> fail msg);
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" []) in
  let goals = Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list in
  match goals with
  | [ goal_json ] ->
    check string "the verdict is observable" "viable"
      (json_state goal_json [ "verification"; "criterion"; "state" ])
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

(* Stage 1 changes no lifecycle semantics: request_complete still completes. *)

let test_request_complete_still_completes_directly () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let created =
    must_succeed
      "create goal"
      (dispatch
         ctx
         ~name:"masc_goal_upsert"
         [ "title", `String "Ungated completion"
         ; "metric", `String "m"
         ; "target_value", `String "1"
         ])
  in
  let goal_id = json_state created [ "goal_id" ] in
  let completed =
    must_succeed
      "request_complete"
      (dispatch
         ctx
         ~name:"masc_goal_transition"
         [ "goal_id", `String goal_id; "action", `String "request_complete" ])
  in
  check string "completed directly (stage 1 keeps main's lifecycle)"
    "completed"
    (json_state completed [ "goal"; "phase" ])
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
    ; ( "ledger round-trip"
      , [ test_case "criterion verdict round-trips" `Quick
            test_criterion_verdict_round_trips
        ; test_case "refuted criterion keeps its reason" `Quick
            test_refuted_criterion_keeps_its_reason
        ] )
    ; ( "ledger record-only discipline"
      , [ test_case "proof verdict requires a pending request" `Quick
            test_proof_verdict_requires_a_pending_request
        ; test_case "human confirmation requires a proven proof" `Quick
            test_human_confirmation_requires_a_proven_proof
        ] )
    ; ( "store discipline"
      , [ test_case "undecodable ledger fails closed and loud" `Quick
            test_undecodable_ledger_fails_closed_and_loud
        ; test_case "unknown ledger field is a decode error" `Quick
            test_unknown_ledger_field_is_a_decode_error
        ] )
    ; ( "observability"
      , [ test_case "goal list joins the ledger" `Quick
            test_goal_list_joins_the_ledger
        ; test_case "goal list renders a ledger-error state" `Quick
            test_goal_list_renders_a_ledger_error_state
        ] )
    ; ( "lifecycle unchanged"
      , [ test_case "request_complete still completes directly" `Quick
            test_request_complete_still_completes_directly
        ] )
    ]
;;
