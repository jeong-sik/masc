(** RFC-0387 — B1 creation requirement + verification ledger + the stage-2
    completion gate.

    B1: creation without a declared success condition ([metric] +
    [target_value]) is a typed rejection. Partial updates retain omitted
    fields, and changed effective criteria must remain non-blank.

    Ledger: verdict commits round-trip through the file store, the decoders
    are strict (unknown fields / unknown variants are decode errors), a store
    that does not decode refuses every mutation AND fails every read loudly —
    never a silent "not verified yet".

    Stage 2 gate: [request_complete] moves Executing -> Verifying and persists
    the durable proof request BEFORE the phase write. Public MCP callers cannot
    name verifier commits. Only the application-owned typed verifier boundary
    can prove/refute completion, with non-blank
    evidence and fixed [verifier_exact] authority. A repeated
    [request_complete] on Verifying wakes an existing pending proof or
    reconciles its verdict. A missing or inconsistent proof does not prove
    that an earlier review ended. The FSM decides phases; the ledger records. *)

open Alcotest
open Masc
open Workspace_types

(* The keeper.world frame prose this suite asserts ("증명 대기 중" in the Active
   Goals rows) moved out of the .ml sources into config/prompts/keeper.md as
   world.* keys, rendered through the prompt registry at assembly time.
   Loading them into the registry is what [Prompt_defaults.init] does below;
   the registry locates config/prompts itself under Dune. *)
let () =
  Masc.Prompt_defaults.init ()
;;

let temp_dir () =
  let path = Filename.temp_file "goal_verification_gate_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

(* [Sys.is_directory] follows a link, so a directory alias is descended into and
   then refused by [Unix.rmdir] (ENOTDIR), while a dangling link reads false from
   [Sys.file_exists] and stays behind (#26648). Classify with [Unix.lstat] so a
   link always loses only itself. *)
let rm_rf dir =
  let rec rm path =
    match Unix.lstat path with
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> ()
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path
      |> Array.iter (fun entry -> rm (Filename.concat path entry));
      Unix.rmdir path
    | _ -> Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace_env f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  (* The server delivers Goal notices with the guard enabled; with it off,
     guarded store mutexes are skipped and a wrong-context call passes. *)
  Eio_guard.enable ();
  let dir = temp_dir () in
  let previous_delivery = Goal_delivery.For_testing.replace_backend
    (Some Server_bootstrap_loops.For_testing.goal_notification_backend) in
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      ignore (Goal_delivery.For_testing.replace_backend previous_delivery);
      rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       f env config)
;;

let with_workspace f = with_workspace_env (fun _env config -> f config)

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

let isolated_criterion =
  Goal_store.Criterion { revision = "test-criterion"; title = "Ledger proof";
    metric = Some "verified services"; target_value = Some "3" }
;;

let current_criterion config goal_id =
  match Goal_store.find_goal config ~goal_id with
  | Goal_store.Goal_found goal -> Goal_store.criterion_of_goal goal
  | Goal_store.Goal_absent -> fail ("missing Goal criterion: " ^ goal_id)
  | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u)
;;

let proof_identity config goal_id =
  match Goal_verification.get_record_authoritative config ~goal_id with
  | Ok (Some { completion = Goal_verification.Proof_pending pending; _ }) ->
    pending.request_id, pending.criterion
  | Ok (Some { completion = Goal_verification.Proof_proven v | Goal_verification.Proof_refuted v; _ }) ->
    v.request_id, v.criterion
  | Ok _ -> fail "test setup needs a bound proof request"
  | Error detail -> fail detail
;;

let verdict ?(evidence = "observed by the verifier")
    ?(request_id = "no-pending-request") ?(criterion = isolated_criterion) outcome : Goal_verification.verdict =
  { Goal_verification.outcome
  ; request_id
  ; criterion
  ; verification_run_id = "goal-verifier-test-run"
  ; authority = Masc_domain.System_llm_agent { agent_run_id = "test-verifier" }
  ; evidence
  ; recorded_at = Masc_domain.now_iso ()
  }
;;

(* Poison both stores to test failed historical reads as well as authoritative
   mutations. A healthy mirror may serve history, but never authorizes a write. *)
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

let test_partial_update_preserves_success_condition () =
  with_workspace
  @@ fun config ->
  let goal, _, _ =
    match
      Goal_store.upsert_goal_with_events ~actor:"test"
        config
        ~title:"Created with a condition"
        ~metric:"m"
        ~target_value:"1"
        ()
    with
    | Ok payload -> payload
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  (* A partial rename uses the stored metric and target when checking the
     changed effective criterion. No re-declaration is required. *)
  match
    Goal_store.upsert_goal_with_events ~actor:"test" config ~id:goal.id ~title:"Renamed" ()
  with
  | Ok (updated, `updated _, _) ->
    check (option string) "metric retained" goal.metric updated.metric;
    check (option string) "target retained" goal.target_value updated.target_value
  | Ok (_, `created, _) -> fail "an existing id must update, not create"
  | Error error -> fail ("partial update rejected: " ^ Goal_store.write_error_to_string error)
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
  match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"x" ~metric:"m" ~target_value:"1" () with
  | Ok _ -> fail "Goal upsert wrote over an undecodable store"
  (* The refusal is the store's typed Unavailable, never the B1 rejection:
     the create/update split is decided only on a state that was read. *)
  | Error (Goal_store.Store_unavailable { reason = Goal_store.Not_json _; _ }) -> ()
  | Error (Goal_store.Store_unavailable _ | Goal_store.Goal_not_found _ | Goal_store.Goal_identity_ambiguous _
          | Goal_store.Rejected _ | Goal_store.Persist_failed _ as other) ->
    fail ("expected Store_unavailable Not_json, got: " ^ Goal_store.write_error_to_string other)
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
      (String_util.contains_substring msg "does not match the pending request")
;;

(* Ledger: strict decode, fail-closed mutations, fail-loud reads *)

let test_undecodable_ledger_fails_closed_and_loud () =
  with_workspace
  @@ fun config ->
  ignore
    (match
       Goal_verification.mark_proof_pending config ~goal_id:"goal-corrupt" ~criterion:isolated_criterion
     with
     | Ok _ -> ()
     | Error msg -> fail msg);
  poison_ledger config;
  (* Mutations refuse. *)
  (match
     Goal_verification.mark_proof_pending config ~goal_id:"goal-corrupt" ~criterion:isolated_criterion
   with
   | Ok _ -> fail "mutation proceeded on an undecodable ledger"
   | Error _ -> ());
  (* Reads fail LOUD: an undecodable ledger is an Error, never [None] — a
     corrupt store must not render as "not verified yet". *)
  (match Goal_verification.get_record_authoritative config ~goal_id:"goal-corrupt" with
   | Ok _ -> fail "lenient read disguised a corrupt ledger as absence"
   | Error msg ->
     check bool "the decode failure is named" true
       (String_util.contains_substring msg "did not decode"));
  match Goal_verification.load_records_by_goal_id_authoritative config with
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
       Goal_verification.mark_proof_pending config ~goal_id:"goal-strict" ~criterion:isolated_criterion
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
  match Goal_verification.get_record_authoritative config ~goal_id:"goal-strict" with
  | Ok _ -> fail "an unknown field decoded silently"
  | Error msg ->
    check bool "the unknown field is named" true
      (String_util.contains_substring msg "surprise_field")
;;

let test_human_confirmation_requires_bound_verdict () =
  with_workspace
  @@ fun config ->
  (match Goal_verification.mark_proof_pending config ~goal_id:"goal-human-missing-verdict" ~criterion:isolated_criterion with
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
  match Goal_verification.get_record_authoritative config ~goal_id:"goal-human-missing-verdict" with
  | Ok _ -> fail "human confirmation without proof decoded silently"
  | Error msg ->
    check bool "the missing bound verdict is rejected" true
      (String_util.contains_substring msg "goal_verification.verdict")
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
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" [ "detailed", `Bool true ]) in
  let goals = Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list in
  (match goals with
   | [ goal_json ] ->
     check string "completion renders idle" "idle"
       (json_state goal_json [ "verification"; "completion"; "state" ])
   | _ -> fail "expected one listed goal");
  (* A durable request shows up in the same join. *)
  ignore
    (match Goal_verification.mark_proof_pending config ~goal_id ~criterion:(current_criterion config goal_id) with
     | Ok _ -> ()
     | Error msg -> fail msg);
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" [ "detailed", `Bool true ]) in
  let goals = Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list in
  (match
     Goal_verification.load_records_by_goal_id_authoritative config
   with
   | Ok records_by_goal_id ->
     check bool "authoritative goal_id map holds the pending proof" true
       (Option.is_some (Goal_store.Goal_id_map.find_opt goal_id records_by_goal_id))
   | Error msg -> fail msg);
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
  let listed = must_succeed "goal list" (dispatch ctx ~name:"masc_goal_list" [ "detailed", `Bool true ]) in
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

let test_measurement_requires_current_criterion_and_evidence () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Measure actual work" in
  let goal =
    match Goal_store.find_goal config ~goal_id with
    | Goal_store.Goal_found goal -> goal
    | Goal_store.Goal_absent | Goal_store.Store_unavailable _ ->
        fail "created Goal is not readable"
  in
  let args revision evidence =
    [ "goal_id", `String goal_id
    ; "criterion_revision", `String revision
    ; "observed_value", `String "0"
    ; "evidence", `String evidence
    ]
  in
  ignore (must_fail "missing evidence"
            (dispatch ctx ~name:"masc_goal_measure"
               (args goal.criterion_revision "")));
  let measured =
    must_succeed "record explicit measurement"
      (dispatch ctx ~name:"masc_goal_measure"
         (args goal.criterion_revision "artifact:measured-count"))
  in
  check string "the tool calls it reported" "reported_only"
    (json_state measured [ "measurement_status" ]);
  check string "recording leaves completion unchanged" "unchanged"
    (json_state measured [ "completion_effect" ]);
  check string "the tool exposes the actual current phase" "executing"
    (json_state measured [ "goal_at_recording"; "phase" ]);
  let first_measurement = Goal_measurement.projection (Goal_measurement.load config) goal in
  check string "actual is stored exactly" "0"
    (json_state first_measurement [ "record"; "observed_value" ]);
  check string "evidence survives" "artifact:measured-count"
    (json_state first_measurement [ "record"; "evidence" ]);
  let listed = must_succeed "goal list after measurement"
      (dispatch ctx ~name:"masc_goal_list" [ "detailed", `Bool true ]) in
  (match Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list with
   | [ goal_json ] ->
       check string "list reports actual state" "reported"
         (json_state goal_json [ "measurement"; "state" ]);
       check string "list preserves reported zero" "0"
         (json_state goal_json [ "measurement"; "record"; "observed_value" ])
   | _ -> fail "expected one listed Goal");
  let cache_before = Goal_projection_generation.current () in
  let notifications = ref 0 in
  let previous_hook = Atomic.get Workspace_hooks.on_goal_projection_mutation_fn in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.on_goal_projection_mutation_fn previous_hook)
    (fun () ->
      Atomic.set Workspace_hooks.on_goal_projection_mutation_fn
        (fun ~base_path:_ -> incr notifications);
      match Goal_measurement.record config ~goal_id
              ~criterion_revision:goal.criterion_revision ~observed_value:"1"
              ~evidence:"artifact:updated-count" ~actor:"test" with
      | Ok _ -> ()
      | Error error -> fail (Goal_measurement.error_to_string error));
  check int "one measurement sends one projection notification" 1 !notifications;
  check int "successful write changes dashboard cache key" (cache_before + 1)
    (Goal_projection_generation.current ());
  (match Goal_measurement.load config with
   | Ok [ row ] ->
       check string "latest replaces prior value" "1" row.observed_value;
       check string "latest replaces prior evidence" "artifact:updated-count" row.evidence
   | Ok _ | Error _ -> fail "measurement snapshot kept more than one row for a Goal");
  let before_revision = Goal_projection_generation.current () in
  let changed =
    match Goal_store.upsert_goal_with_events ~actor:"test" config ~id:goal_id ~target_value:"2" () with
    | Ok (goal, _, _) -> goal
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  check bool "criterion change refreshes dashboard cache" true
    (Goal_projection_generation.current () > before_revision);
  check string "old criterion is not current" "not_recorded"
    (json_state (Goal_measurement.projection (Goal_measurement.load config) changed)
       [ "state" ]);
  let listed = must_succeed "goal list after criterion revision"
      (dispatch ctx ~name:"masc_goal_list" [ "detailed", `Bool true ]) in
  (match Yojson.Safe.Util.member "goals" listed |> Yojson.Safe.Util.to_list with
   | [ goal_json ] ->
       check string "revised criterion has no actual" "not_recorded"
         (json_state goal_json [ "measurement"; "state" ])
   | _ -> fail "expected one listed Goal");
  ignore (must_fail "stale criterion"
            (dispatch ctx ~name:"masc_goal_measure"
               (args goal.criterion_revision "artifact:stale")))
;;

let transition ctx goal_id ?note ?evidence action =
  (* A drop must say why; a test that does not care gets this sentence. *)
  let note = match note with
    | None when String.equal action "drop" -> Some "scenario no longer needs this Goal"
    | Some _ | None -> note in
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

let measurable_goal config ctx title =
  let goal_id = create_goal ctx title in
  match Goal_store.find_goal config ~goal_id with
  | Goal_store.Goal_found goal -> goal
  | Goal_store.Goal_absent | Goal_store.Store_unavailable _ ->
      fail "created Goal is not readable"
;;

let record_evidence config (goal : Goal_store.goal) evidence =
  Goal_measurement.record config ~goal_id:goal.id
    ~criterion_revision:goal.criterion_revision ~observed_value:"7" ~evidence
    ~actor:"test"
;;

let test_measurement_receipt_preserves_lifecycle_and_criterion () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal = measurable_goal config ctx "Measurement reports lifecycle, not completion" in
  List.iter
    (fun phase ->
       let at_recording =
         match Goal_store.transact_goal config ~goal_id:goal.id
                 (fun current -> Ok ({ current with phase }, ())) with
         | Ok (current, ()) -> current
         | Error error -> fail (Goal_store.write_error_to_string error)
       in
       let paths = [ Goal_store.goals_path config; Goal_store.goals_path config ^ ".last-good" ] in
       let before = List.map (fun path -> path, Fs_compat.load_file path) paths in
       let receipt = must_succeed "measure an existing lifecycle state"
           (dispatch ctx ~name:"masc_goal_measure"
              [ "goal_id", `String goal.id
              ; "criterion_revision", `String at_recording.criterion_revision
              ; "observed_value", `String "1"
              ; "evidence", `String "note:the declared metric was observed"
              ]) in
       check string "measurement remains a report" "reported_only"
         (json_state receipt [ "measurement_status" ]);
       check string "measurement performs no completion transition" "unchanged"
         (json_state receipt [ "completion_effect" ]);
       check bool "receipt binds the exact Goal, including suspension restore state" true
         (Yojson.Safe.Util.member "goal_at_recording" receipt
          = Goal_store.goal_to_yojson at_recording);
       check bool "report is not named verification" true
         (Yojson.Safe.Util.member "verification" receipt = `Null);
       List.iter (fun (path, bytes) ->
         check string "recording leaves Goal lifecycle bytes unchanged" bytes
           (Fs_compat.load_file path)) before;
       let stored = Yojson.Safe.from_string (Fs_compat.load_file (Goal_measurement.path config)) in
       (match Yojson.Safe.Util.member "measurements" stored with
        | `List [ `Assoc fields ] ->
            check (list string) "durable observation schema has no receipt or lifecycle copy"
              [ "actor"; "criterion_revision"; "evidence"; "goal_id"; "id";
                "observed_value"; "recorded_at" ]
              (List.sort String.compare (List.map fst fields))
        | _ -> fail "expected one durable measurement row"))
    Goal_phase.all;
  let receipt = match record_evidence config goal "note:before a criterion edit" with
    | Ok receipt -> receipt
    | Error error -> fail (Goal_measurement.error_to_string error) in
  let captured = `Assoc (Goal_measurement.receipt_fields receipt) in
  let changed = match Goal_store.upsert_goal_with_events ~actor:"test" config ~id:goal.id ~target_value:"2" () with
    | Ok (changed, _, _) -> changed
    | Error error -> fail (Goal_store.write_error_to_string error) in
  check bool "criterion really changed after recording" true
    (changed.criterion_revision <> receipt.goal_at_recording.criterion_revision);
  check bool "serializing an issued receipt does not reread a later Goal" true
    (captured = `Assoc (Goal_measurement.receipt_fields receipt));
  check string "measurement and transaction Goal name the same criterion"
    receipt.measurement.criterion_revision receipt.goal_at_recording.criterion_revision;
  (match record_evidence config goal "note:stale criterion" with
   | Error (Goal_measurement.Conflict _) -> ()
   | Ok _ -> fail "a stale criterion produced a receipt"
   | Error error -> fail (Goal_measurement.error_to_string error))
;;

(* "Evidence-backed" means the product's Evidence Reference grammar, the one
   Task completion accepts, not any non-blank text: a Keeper sending
   evidence "done" must not put a reported value on the Goal tree. *)
let test_measurement_evidence_is_an_evidence_reference () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal = measurable_goal config ctx "Evidence must resolve" in
  List.iter
    (fun evidence ->
       match record_evidence config goal evidence with
       | Error (Goal_measurement.Invalid_request _) -> ()
       | Error ((Goal_measurement.Conflict _ | Goal_measurement.Store_error _) as error) ->
           fail
             (Printf.sprintf "evidence %S: expected Invalid_request, got %s" evidence
                (Goal_measurement.error_to_string error))
       | Ok _ -> fail (Printf.sprintf "evidence %S is not a reference but was recorded" evidence))
    [ "done"; "100%"; "https://example.com/proof"; "note:   "; "board:";
      "artifact:"; "artifact:/abs"; "artifact:../x" ];
  (match Goal_measurement.load config with
   | Ok [] -> ()
   | Ok _ -> fail "rejected evidence left a measurement row"
   | Error detail -> fail detail);
  let refused =
    must_fail "tool rejects evidence that is not a reference"
      (dispatch ctx ~name:"masc_goal_measure"
         [ "goal_id", `String goal.id
         ; "criterion_revision", `String goal.criterion_revision
         ; "observed_value", `String "100%"
         ; "evidence", `String "done"
         ])
  in
  check string "the tool refuses it as a validation error"
    (Tool_args.error_code_to_string Tool_args.Validation_error)
    (json_state refused [ "error_code" ]);
  List.iter
    (fun evidence ->
       match record_evidence config goal evidence with
       | Ok receipt ->
           check string "reference is stored as given" evidence
             receipt.measurement.evidence
       | Error error ->
           fail
             (Printf.sprintf "evidence %S was refused: %s" evidence
                (Goal_measurement.error_to_string error)))
    [ "artifact:reports/cases.json"; "note:seven cases passed in CI"; "board:p-123";
      "fusion:run-9" ]
;;

(* The store is read with the same evidence check: a row whose evidence is
   not a reference makes the snapshot unreadable instead of being shown as a
   reported value. The first write is the control that the hand-written row
   shape is one [load] accepts. *)
let test_stored_non_reference_evidence_is_unreadable () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal = measurable_goal config ctx "Stored evidence is checked" in
  let store evidence =
    Fs_compat.save_file (Goal_measurement.path config)
      (Yojson.Safe.to_string
         (`Assoc
           [ "version", `Int 1
           ; "measurements",
             `List
               [ `Assoc
                   [ "id", `String "measurement-1"
                   ; "goal_id", `String goal.id
                   ; "criterion_revision", `String goal.criterion_revision
                   ; "observed_value", `String "7"
                   ; "evidence", `String evidence
                   ; "actor", `String "test"
                   ; "recorded_at", `String "2026-09-25T00:00:00Z"
                   ]
               ]
           ]))
  in
  store "artifact:reports/cases.json";
  (match Goal_measurement.load config with
   | Ok [ row ] -> check string "control row loads" "artifact:reports/cases.json" row.evidence
   | Ok rows -> fail (Printf.sprintf "control: expected 1 row, found %d" (List.length rows))
   | Error detail -> fail ("control row was refused: " ^ detail));
  store "done";
  (match Goal_measurement.load config with
   | Error _ -> ()
   | Ok _ -> fail "a stored row with evidence \"done\" was loaded");
  check string "the Goal shows the store as unavailable" "unavailable"
    (json_state (Goal_measurement.projection (Goal_measurement.load config) goal) [ "state" ])
;;

(* Deleting a Goal takes its observation row with it, so the snapshot is
   bounded by the Goals that exist. A closed Goal still takes an
   observation: recording never moves the phase. *)
let test_measurement_rows_follow_goal_existence_not_phase () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let kept = measurable_goal config ctx "Kept" in
  let deleted = measurable_goal config ctx "Deleted" in
  List.iter
    (fun (goal, evidence) ->
       match record_evidence config goal evidence with
       | Ok _ -> ()
       | Error error -> fail (Goal_measurement.error_to_string error))
    [ kept, "artifact:kept"; deleted, "artifact:deleted" ];
  (match Goal_store.delete_goal config ~goal_id:deleted.id with
   | Ok _ -> ()
   | Error error -> fail (Goal_store.delete_goal_error_to_string error));
  (match Goal_measurement.remove_goal config ~goal_id:deleted.id with
   | Ok () -> ()
   | Error detail -> fail detail);
  (match Goal_measurement.load config with
   | Ok [ row ] -> check string "only the live Goal keeps a row" kept.id row.goal_id
   | Ok rows -> fail (Printf.sprintf "expected 1 row, found %d" (List.length rows))
   | Error detail -> fail detail);
  ignore (must_succeed "drop" (transition ctx kept.id "drop"));
  (match record_evidence config kept "note:metric seen again after the drop" with
   | Ok receipt ->
       check string "a dropped Goal records the new observation"
         "note:metric seen again after the drop" receipt.measurement.evidence;
       check string "the receipt records its actual dropped phase" "dropped"
         (Goal_phase.to_string receipt.goal_at_recording.phase)
   | Error error -> fail (Goal_measurement.error_to_string error));
  (match Goal_store.find_goal config ~goal_id:kept.id with
   | Goal_store.Goal_found goal ->
       check string "the observation did not move the phase" "dropped"
         (Goal_phase.to_string goal.phase)
   | Goal_store.Goal_absent | Goal_store.Store_unavailable _ ->
       fail "dropped Goal is not readable")
;;

let verifier_transition config goal_id decision evidence =
  let request_id, criterion = proof_identity config goal_id in
  Workspace_goals.commit_verifier_decision
    ~tool_name:"goal_verifier_commit"
    ~start_time:(Tool_timing.start ())
    config
    ~goal_id
    ~verification_run_id:"goal-verifier-test-run"
    ~request_id
    ~criterion
    ~decision
    ~evidence
;;

let stored_phase config goal_id =
  match Goal_store.find_goal config ~goal_id with
  | Goal_store.Goal_found goal -> Goal_phase.to_string goal.Goal_store.phase
  | Goal_store.Goal_absent -> fail ("goal not found: " ^ goal_id)
  | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u)
;;

let ledger_record config goal_id =
  match Goal_verification.get_record_authoritative config ~goal_id with
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
let test_reopen_without_any_verification_history () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Reopen before any completion request" in
  let path = Goal_verification.verifications_path config in
  check bool "creation does not need a proof ledger" false (Sys.file_exists path);
  let repeated = must_succeed "already executing without proof" (transition ctx goal_id "reopen") in
  check bool "fresh goal reopen is a no-op" true (json_bool repeated [ "noop" ]);
  ignore (must_succeed "drop" (transition ctx goal_id "drop"));
  let reopened = must_succeed "reopen without proof" (transition ctx goal_id "reopen") in
  check string "reopened goal executes" "executing" (json_state reopened [ "goal"; "phase" ]);
  check bool "reopen invents no verification history" false (Sys.file_exists path)
;;

let test_reopened_goal_enters_a_new_verification_cycle () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Reopen a proven goal" in
  ignore (must_succeed "first request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "first proof"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "original proof"));
  let previous = ledger_record config goal_id in
  ignore (must_succeed "reopen" (transition ctx goal_id "reopen"));
  check string "reopen returns to execution" "executing" (stored_phase config goal_id);
  check bool "the previous proof is no longer the active proof" true
    ((ledger_record config goal_id).completion = Goal_verification.Completion_idle);
  let history = goal_events_text config in
  let archived =
    String.split_on_char '\n' history
    |> List.filter (fun line -> String.trim line <> "")
    |> List.map Yojson.Safe.from_string
    |> List.filter (fun event ->
      json_state event [ "event_type" ] = "goal_proof_reopened")
  in
  (match archived, previous.completion with
   | [ event ], Goal_verification.Proof_proven verdict ->
     check string "original evidence remains in history" verdict.evidence
       (json_state event [ "payload"; "previous_completion"; "verdict"; "evidence" ]);
     check string "original verifier attempt remains in history" verdict.verification_run_id
       (json_state event [ "payload"; "previous_completion"; "verdict"; "verification_run_id" ]);
     check string "original proof time remains in history" verdict.recorded_at
       (json_state event [ "payload"; "previous_completion"; "verdict"; "recorded_at" ])
   | _ -> fail "reopen must preserve the original verdict once");
  let repeated = must_succeed "repeat reopened execution" (transition ctx goal_id "reopen") in
  check bool "repeated reopen is a no-op" true (json_bool repeated [ "noop" ]);
  check string "repeated reopen emits no duplicate history" history (goal_events_text config);
  ignore (must_succeed "new completion request" (transition ctx goal_id "request_complete"));
  check string "new request reaches verifying" "verifying" (stored_phase config goal_id);
  (match Goal_verification_agent.For_testing.collect_pending config with
   | Ok { Goal_verification_agent.For_testing.collected = work; _ } -> check bool "the verifier can collect the new proof request" true
       (List.exists (fun (work : Goal_verification_agent.For_testing.pending_work) -> work.goal_id = goal_id) work)
   | Error failure -> fail (Goal_verification_agent.For_testing.scan_failure_to_string failure));
  (* Reopen from the new Verifying goes back to Executing and archives the
     pending request; the stale request cannot be answered afterwards. *)
  let stale_request, stale_criterion = proof_identity config goal_id in
  ignore (must_succeed "reopen from verifying" (transition ctx goal_id "reopen"));
  check string "reopen from verifying returns to execution" "executing" (stored_phase config goal_id);
  check bool "the pending request is no longer active" true
    ((ledger_record config goal_id).completion = Goal_verification.Completion_idle);
  let archived_pending =
    String.split_on_char '\n' (goal_events_text config)
    |> List.filter (fun line -> String.trim line <> "")
    |> List.map Yojson.Safe.from_string
    |> List.filter (fun event ->
      json_state event [ "event_type" ] = "goal_proof_reopened"
      && (match Yojson.Safe.Util.(event |> member "payload" |> member "previous_completion"
                                   |> member "request_id") with
          | `String request_id -> String.equal request_id stale_request
          | _ -> false))
  in
  check int "the pending request is archived once" 1 (List.length archived_pending);
  ignore (must_fail "stale answer after reopen"
    (Workspace_goals.commit_verifier_decision ~tool_name:"goal_verifier_commit"
       ~start_time:(Tool_timing.start ()) config ~goal_id ~request_id:stale_request ~criterion:stale_criterion
       ~verification_run_id:"stale-verifier-run"
       ~decision:Workspace_goals.Proof_proven ~evidence:"stale proof"));
  check string "stale answer leaves the goal executing" "executing" (stored_phase config goal_id);
  ignore (must_succeed "third completion request" (transition ctx goal_id "request_complete"));
  let request_id, criterion = proof_identity config goal_id in
  ignore (must_succeed "second proof"
    (Workspace_goals.commit_verifier_decision ~tool_name:"goal_verifier_commit"
       ~start_time:(Tool_timing.start ()) config ~goal_id ~request_id ~criterion ~verification_run_id:"second-verifier-run"
       ~decision:Workspace_goals.Proof_proven ~evidence:"new execution proof"));
  check string "new execution can complete" "awaiting_confirmation" (stored_phase config goal_id);
  match (ledger_record config goal_id).completion with
  | Goal_verification.Proof_proven verdict ->
    check string "new proof owns the active verdict" "second-verifier-run" verdict.verification_run_id
  | _ -> fail "second execution did not retain its own proof"
;;

(* A goal failure takes its class from its error code
   ([Tool_args.failure_class_of_error_code]). An argument the caller can
   correct is a policy rejection; a phase that does not admit the call is a
   workflow rejection. *)
let test_goal_failures_take_the_class_of_their_code () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let class_of result =
    Option.map Tool_result.tool_failure_class_to_string (Tool_result.failure_class result)
  in
  let goal_id = create_goal ctx "Classify goal failures" in
  check (option string) "an action that does not exist"
    (Some "policy_rejection")
    (class_of (transition ctx goal_id "not_an_action"));
  check (option string) "a goal that does not exist"
    (Some "policy_rejection")
    (class_of (transition ctx "goal-that-does-not-exist" "drop"));
  ignore (must_succeed "drop" (transition ctx goal_id "drop"));
  check (option string) "evidence for a goal with no proof request"
    (Some "workflow_rejection")
    (class_of
       (dispatch ctx ~name:"masc_goal_transition"
          [ "goal_id", `String goal_id
          ; "action", `String "request_complete"
          ; "evidence_refs", `List [ `String "board:post-1" ]
          ]))
;;

let test_dropped_pending_proof_gets_a_new_request_after_reopen () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Drop a request before its phase write" in
  let criterion = current_criterion config goal_id in
  (match Goal_verification.mark_proof_pending config ~goal_id ~criterion with
   | Ok _ -> () | Error detail -> fail detail);
  let old_request, old_criterion = proof_identity config goal_id in
  ignore (must_succeed "drop before phase write" (transition ctx goal_id "drop"));
  ignore (must_succeed "reopen" (transition ctx goal_id "reopen"));
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Completion_idle -> ()
   | _ -> fail "reopen retained the abandoned pending request");
  let archived = String.split_on_char '\n' (goal_events_text config)
    |> List.filter (fun text -> String.trim text <> "")
    |> List.map Yojson.Safe.from_string
    |> List.find (fun event -> json_state event [ "event_type" ] = "goal_proof_reopened") in
  check string "abandoned request remains in history" old_request
    (json_state archived [ "payload"; "previous_completion"; "request_id" ]);
  ignore (must_succeed "new request" (transition ctx goal_id "request_complete"));
  let new_request, _ = proof_identity config goal_id in
  check bool "new execution has a distinct request identity" false
    (String.equal old_request new_request);
  ignore (must_fail "old answer after reopen"
    (Workspace_goals.commit_verifier_decision ~tool_name:"goal_verifier_commit"
       ~start_time:(Tool_timing.start ()) config ~goal_id ~verification_run_id:"old-run"
       ~request_id:old_request ~criterion:old_criterion
       ~decision:Workspace_goals.Proof_proven ~evidence:"old execution proof"));
  check string "new execution remains verifying" "verifying" (stored_phase config goal_id);
  let still_pending, _ = proof_identity config goal_id in
  check string "old answer did not consume the new request" new_request still_pending
;;

(* The operator can leave [Verifying] without a verdict. A verdict the verifier
   delivers afterwards names a phase the goal is no longer in: it is refused,
   the goal stays where the operator put it, and the ledger does not take it. *)
let test_verdict_after_drop_from_verifying_is_refused () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Drop while the verifier is silent" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  check string "verifying before drop" "verifying" (stored_phase config goal_id);
  let request_id, criterion = proof_identity config goal_id in
  let dropped = must_succeed "drop from verifying" (transition ctx goal_id "drop") in
  check string "drop moves verifying to dropped" "dropped"
    (json_state dropped [ "goal"; "phase" ]);
  ignore (must_fail "late verdict after drop"
    (Workspace_goals.commit_verifier_decision ~tool_name:"goal_verifier_commit"
       ~start_time:(Tool_timing.start ()) config ~goal_id ~verification_run_id:"late-run"
       ~request_id ~criterion
       ~decision:Workspace_goals.Proof_proven ~evidence:"late proof"));
  check string "late verdict does not resurrect the goal" "dropped"
    (stored_phase config goal_id);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_proven _ | Goal_verification.Proof_refuted _
   | Goal_verification.Human_confirmed _ -> fail "late verdict was recorded"
   | Goal_verification.Proof_pending _ | Goal_verification.Completion_idle -> ())
;;

let test_reopen_from_verifying_clears_the_pending_request () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Reopen while the verifier is silent" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let request_id, criterion = proof_identity config goal_id in
  let reopened = must_succeed "reopen from verifying" (transition ctx goal_id "reopen") in
  check string "reopen moves verifying to executing" "executing"
    (json_state reopened [ "goal"; "phase" ]);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Completion_idle -> ()
   | _ -> fail "reopen from verifying retained the pending request");
  ignore (must_fail "late refutation after reopen"
    (Workspace_goals.commit_verifier_decision ~tool_name:"goal_verifier_commit"
       ~start_time:(Tool_timing.start ()) config ~goal_id ~verification_run_id:"late-run"
       ~request_id ~criterion
       ~decision:(Workspace_goals.Proof_refuted { reason = "late" })
       ~evidence:"late refutation"));
  check string "late verdict leaves the goal executing" "executing"
    (stored_phase config goal_id)
;;

let test_repeated_reopen_preserves_a_new_refuted_proof () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "A repeated reopen cannot erase a new refutation" in
  ignore (must_succeed "first request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "first proof"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "first proof"));
  ignore (must_succeed "reopen" (transition ctx goal_id "reopen"));
  ignore (must_succeed "new request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "new refutation"
    (verifier_transition config goal_id
      (Workspace_goals.Proof_refuted { reason = "new work is not proven" })
      "new work is not proven"));
  let path = Goal_verification.verifications_path config in
  let before = Fs_compat.load_file path in
  let history = goal_events_text config in
  let repeated = must_succeed "delayed repeated reopen" (transition ctx goal_id "reopen") in
  check bool "repeated reopen is a noop" true (json_bool repeated [ "noop" ]);
  check string "the new proof is not erased" before (Fs_compat.load_file path);
  check string "no redundant history is emitted" history (goal_events_text config)
;;

let test_reopen_archive_failure_is_recoverable_without_losing_proof () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Retry a reopened proof archive" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "proof"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "preserve this proof"));
  let original = ledger_record config goal_id in
  let path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  let history = Fs_compat.load_file path in
  Fs_compat.invalidate_cached_writer path;
  Sys.remove path;
  Unix.mkdir path 0o755;
  let refused = must_fail "archive failure" (transition ctx goal_id "reopen") in
  check string "archive failure is explicit" "internal_error" (json_state refused [ "error_code" ]);
  check string "archive failure leaves the original phase" "awaiting_confirmation" (stored_phase config goal_id);
  check bool "archive failure retains the original active proof" true
    (original = ledger_record config goal_id);
  Unix.rmdir path;
  Fs_compat.save_file path history;
  ignore (must_succeed "reopen retries its unfinished reset" (transition ctx goal_id "reopen"));
  ignore (must_succeed "new request after repair" (transition ctx goal_id "request_complete"));
  check string "repaired reopen does not remain blocked by old proof" "verifying"
    (stored_phase config goal_id)
;;

let test_reopen_reset_refuses_an_unreadable_goal_source () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Unreadable goal during reopen" in
  let path = Goal_store.goals_path config in
  let executing_snapshot = Fs_compat.load_file path in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "proof"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "still authoritative"));
  let original = ledger_record config goal_id in
  let ledger_path = Goal_verification.verifications_path config in
  let ledger_bytes = Fs_compat.load_file ledger_path in
  let history = goal_events_text config in
  Fs_compat.save_file path "not JSON";
  Fs_compat.save_file (path ^ ".last-good") executing_snapshot;
  (match Goal_verification.reopen_goal config ~goal_id ~note:None ~actor:"reopener" with
   | Error detail -> check bool "read failure retains its explanation" true (String.trim detail <> "")
   | Ok _ -> fail "a recovery snapshot cannot authorize proof reset");
  check bool "read failure never becomes an idle proof" true
    (original = ledger_record config goal_id);
  check string "ledger bytes are preserved" ledger_bytes (Fs_compat.load_file ledger_path);
  check string "invalid primary is not rewritten" "not JSON" (Fs_compat.load_file path);
  check string "no fabricated reopen archive" history (goal_events_text config)
;;

let test_reopen_reset_refuses_a_recovered_verification_ledger () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Unreadable proof during reopen" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "proof"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "preserve primary authority"));
  (* Model the persisted phase write before a failed reset, so a recovered
     proven ledger would otherwise be overwritten with idle. *)
  (match Goal_store.transact_goal config ~goal_id
     (fun goal -> Ok ({ goal with phase = Goal_phase.Executing }, ())) with
   | Ok _ -> ()
   | Error _ -> fail "could not enter the reopen recovery boundary");
  let path = Goal_verification.verifications_path config in
  let mirror = Fs_compat.load_file (path ^ ".last-good") in
  let history = goal_events_text config in
  Fs_compat.save_file path "not JSON";
  (match Goal_verification.reopen_goal config ~goal_id ~note:None ~actor:"reopener" with
   | Error _ -> ()
   | Ok _ -> fail "a recovered ledger cannot authorize proof reset");
  check string "invalid ledger primary is preserved" "not JSON" (Fs_compat.load_file path);
  check string "readable ledger mirror is preserved" mirror
    (Fs_compat.load_file (path ^ ".last-good"));
  check string "unreadable ledger produces no archive" history (goal_events_text config);
  Sys.remove path;
  (match Goal_verification.reopen_goal config ~goal_id ~note:None ~actor:"reopener" with
   | Error _ -> ()
   | Ok _ -> fail "a missing primary with a surviving mirror is not a new empty ledger");
  check bool "missing primary is not recreated from mirror" false (Sys.file_exists path);
  check string "mirror remains unchanged when primary is missing" mirror
    (Fs_compat.load_file (path ^ ".last-good"))
;;

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

let test_blank_public_criterion_edits_preserve_pending_proof () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Keep pending proof" in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  let proof_before = proof_identity config goal_id in
  let primary = Goal_store.goals_path config in
  let proof_path = Goal_verification.verifications_path config in
  let ledger = Filename.concat (Filename.dirname primary) "goal_events.jsonl" in
  let paths = [primary; primary ^ ".last-good"; proof_path;
    proof_path ^ ".last-good"; ledger] in
  let snapshots = List.map (fun path -> path, Fs_compat.load_file path) paths in
  List.iter (fun field ->
    List.iter (fun blank ->
      let rejected = must_fail "blank public criterion edit"
          (dispatch ctx ~name:"masc_goal_upsert"
            ["id", `String goal_id; field, `String blank]) in
      check string "typed validation error" "validation_error"
        (json_state rejected ["error_code"]);
      List.iter (fun (path, bytes) ->
        check string ("refusal preserves " ^ Filename.basename path) bytes
          (Fs_compat.load_file path)) snapshots;
      check bool "bound request and criterion are unchanged" true
        (proof_before = proof_identity config goal_id);
      check string "goal remains verifying" "verifying" (stored_phase config goal_id))
      [""; " \t\n"])
    ["title"; "metric"; "target_value"]
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
  let request_id, criterion = proof_identity config goal_id in
  let unbound_attempt =
    must_fail "typed proof verdict with blank run ID"
      (Workspace_goals.commit_verifier_decision
         ~tool_name:"goal_verifier_commit"
         ~start_time:(Tool_timing.start ())
         config
         ~goal_id
         ~verification_run_id:"   "
         ~request_id
         ~criterion
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
  check string "completed via proof" "awaiting_confirmation"
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

type inconsistent_verifying_fixture = Missing | Idle | Stale | Same_revision | Confirmed

(* A missing or inconsistent row is not evidence that its original review
   ended. Exercise every public and scan admission without creating another ID. *)
let test_verifying_does_not_recreate_an_unknown_request () =
  List.iter (fun fixture ->
    with_workspace @@ fun config ->
    let ctx = workspace_ctx config in
    let goal_id = create_goal ctx "Uncertain proof" in
    (match fixture with
     | Missing -> ()
     | Same_revision ->
       let Goal_store.Criterion criterion = current_criterion config goal_id in
       let old = Goal_store.Criterion {criterion with title=criterion.title ^ " changed"} in
       (match Goal_verification.mark_proof_pending config ~goal_id ~criterion:old with
        | Ok _ -> () | Error detail -> fail detail)
     | Idle | Stale | Confirmed ->
       ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
       (match fixture with
        | Idle ->
          (match Goal_verification.reopen_goal config ~goal_id ~actor:"operator" ~note:None with
           | Ok _ -> () | Error detail -> fail detail)
        | Stale ->
          (match Goal_store.upsert_goal_with_events ~actor:"test" config ~id:goal_id ~target_value:"4" () with
           | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error))
        | Confirmed ->
          let request_id, criterion = proof_identity config goal_id in
          let proof = verdict ~request_id ~criterion Goal_verification.Proven in
          (match Goal_verification.record_proof_verdict config ~goal_id proof with
           | Ok _ -> () | Error detail -> fail detail);
          (match Goal_verification.record_human_confirmation config ~goal_id proof ~operator_id:"operator" with
           | Ok _ -> () | Error detail -> fail detail)
        | Missing | Same_revision -> ()));
    (match fixture with
     | Confirmed -> ()
     | Missing | Idle | Stale | Same_revision ->
       (match Goal_store.transact_goal config ~goal_id
                (fun goal -> Ok ({ goal with Goal_store.phase = Goal_phase.Verifying }, ())) with
        | Ok _ -> ()
        | Error error -> fail (Goal_store.write_error_to_string error)));
    let read_file path = if Sys.file_exists path then Some (Fs_compat.load_file path) else None in
    let goal_path = Goal_store.goals_path config in
    let ledger_path = Goal_verification.verifications_path config in
    let before_goal = read_file goal_path and before_ledger = read_file ledger_path in
    let before_mirror = read_file (ledger_path ^ ".last-good") in
    let before_events = goal_events_text config in
    let wakes = ref 0 in
    let old = Atomic.exchange Workspace_hooks.goal_verification_pending_fn
      (fun _ ~goal_id:_ -> incr wakes) in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_pending_fn old)
      (fun () ->
        List.iter (fun evidence_refs ->
          let args = ["goal_id", `String goal_id; "action", `String "request_complete"]
            @ (match evidence_refs with None -> [] | Some refs -> ["evidence_refs", `List (List.map (fun s -> `String s) refs)]) in
          let error = must_fail "uncertain verification" (dispatch ctx ~name:"masc_goal_transition" args) in
          check string "the inconsistency is a conflict" "conflict" (json_state error ["error_code"]))
          [None; Some ["board:missing-proof-source"]];
        (match Workspace_goals.recover_current_proof config ~goal_id with
         | Error (Goal_store.Rejected _) -> ()
         | Error _ | Ok _ -> fail "scan recovery did not report the inconsistency");
        (match Goal_verification.bind_review config ~goal_id with
         | Error (Goal_verification.Binding_unavailable _) -> ()
         | Error (Goal_verification.No_current_review _) | Ok _ ->
           fail "uncertainty must retain any existing retry");
        check (option string) "Goal stays unchanged" before_goal (read_file goal_path);
        check (option string) "primary proof stays unchanged" before_ledger (read_file ledger_path);
        check (option string) "mirror stays unchanged" before_mirror (read_file (ledger_path ^ ".last-good"));
        check string "no Goal event is added" before_events (goal_events_text config);
        check int "no verification is woken" 0 !wakes))
    [Missing; Idle; Stale; Same_revision; Confirmed]
;;

let test_verifying_retry_preserves_its_evidence_snapshot () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Pending evidence" in
  let criterion = current_criterion config goal_id in
  let content = {|{"source":"original submitted evidence"}|} in
  let item = Workspace_verification_store.Evidence_collaboration {
    reference="board:original"; content;
    sha256=Agent_core_sha256.(to_hex (digest_string content)) } in
  (match Goal_verification.mark_proof_pending ~submitted_evidence:[item] config ~goal_id ~criterion with
   | Ok _ -> () | Error detail -> fail detail);
  ignore (must_succeed "start proof" (transition ctx goal_id "request_complete"));
  let original_id, _ = proof_identity config goal_id in
  let ledger_path = Goal_verification.verifications_path config in
  let before = Fs_compat.load_file ledger_path in
  let response = dispatch ctx ~name:"masc_goal_transition"
    ["goal_id", `String goal_id; "action", `String "request_complete"; "evidence_refs", `List []] in
  let error = must_fail "different evidence during an active proof" response in
  check string "changed evidence conflicts" "conflict" (json_state error ["error_code"]);
  check string "the original proof bytes are unchanged" before (Fs_compat.load_file ledger_path);
  let retained_id, _ = proof_identity config goal_id in
  check string "the original request remains current" original_id retained_id;
  ignore (must_succeed "ordinary retry" (transition ctx goal_id "request_complete"));
  check bool "omitted evidence retains the snapshot" true
    ((ledger_record config goal_id).submitted_evidence = [item]);
  let empty_goal = create_goal ctx "Empty pending evidence" in
  ignore (must_succeed "start empty proof" (transition ctx empty_goal "request_complete"));
  let empty_id, _ = proof_identity config empty_goal in
  ignore (must_succeed "retry the same explicit evidence" (dispatch ctx ~name:"masc_goal_transition"
    ["goal_id", `String empty_goal; "action", `String "request_complete"; "evidence_refs", `List []]));
  let repeated_id, _ = proof_identity config empty_goal in
  check string "the same evidence keeps its request" empty_id repeated_id
;;

let test_bound_retry_does_not_create_or_replace_a_request () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Bound retry" in
  let Goal_store.Criterion {revision=initial_revision; _} = current_criterion config goal_id in
  ignore (must_succeed "initial request" (transition ctx goal_id "request_complete"));
  let request_id, Goal_store.Criterion {revision; _} = proof_identity config goal_id in
  ignore (must_fail "a stale executing click must not retry another actor's request"
    (dispatch ctx ~name:"masc_goal_transition"
       ["goal_id", `String goal_id; "action", `String "request_complete";
        "expected_verification", `Assoc ["phase", `String "executing";
          "criterion_revision", `String initial_revision]]));
  let still_original, _ = proof_identity config goal_id in
  check string "the other actor's request is unchanged" request_id still_original;
  let retry () = dispatch ctx ~name:"masc_goal_transition"
      ["goal_id", `String goal_id; "action", `String "request_complete";
       "expected_verification", `Assoc ["phase", `String "verifying"; "criterion_revision", `String revision;
         "request_id", `String request_id]] in
  ignore (must_succeed "current retry" (retry ()));
  ignore (must_succeed "the verifier refutes the original"
    (verifier_transition config goal_id
       (Workspace_goals.Proof_refuted {reason="target not met"}) "target not met"));
  ignore (must_fail "old retry must not start a new request after refutation" (retry ()));
  check string "the old click leaves the Goal executing" "executing" (stored_phase config goal_id);
  ignore (must_succeed "a new explicit completion request" (transition ctx goal_id "request_complete"));
  let replacement, _ = proof_identity config goal_id in
  check bool "the replacement request has its own identity" false (String.equal request_id replacement);
  ignore (must_fail "old retry must not target the replacement" (retry ()));
  let observed, _ = proof_identity config goal_id in
  check string "the replacement remains untouched" replacement observed
;;

(* [request_complete] as a client sends it after reading the Goal: the
   expected binding names the phase, revision and request it read. *)
let request_complete_bound ctx ~goal_id ?evidence_refs expected =
  dispatch ctx ~name:"masc_goal_transition"
    ([ "goal_id", `String goal_id; "action", `String "request_complete";
       "expected_verification", `Assoc expected ]
     @ match evidence_refs with
       | None -> []
       | Some refs -> [ "evidence_refs", `List (List.map (fun r -> `String r) refs) ])
;;

(* A retry bound to the Verifying Goal it read is refused once another
   transition has moved that Goal. *)
let test_verifying_repeat_refuses_changed_goal () =
  List.iter (fun action ->
    with_workspace @@ fun config ->
    let ctx = workspace_ctx config in
    let goal_id = create_goal ctx ("Retry races " ^ action) in
    ignore (must_succeed "initial request" (transition ctx goal_id "request_complete"));
    let request_id, Goal_store.Criterion { revision; _ } = proof_identity config goal_id in
    ignore (must_succeed "intervening Goal transition" (transition ctx goal_id action));
    let goal_path = Goal_store.goals_path config in
    let ledger_path = Goal_verification.verifications_path config in
    let before_goal = Fs_compat.load_file goal_path in
    let before_ledger = Fs_compat.load_file ledger_path in
    let wakes = ref 0 in
    let old = Atomic.exchange Workspace_hooks.goal_verification_pending_fn
      (fun _ ~goal_id:_ -> incr wakes) in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_pending_fn old)
      (fun () ->
        List.iter (fun evidence_refs ->
          let answer = request_complete_bound ctx ~goal_id ?evidence_refs
              [ "phase", `String "verifying"; "criterion_revision", `String revision
              ; "request_id", `String request_id ] in
          let error = must_fail ("retry after " ^ action) answer in
          check string "current phase is a conflict" "conflict" (json_state error ["error_code"]);
          check string "rejected retry leaves Goal unchanged" before_goal (Fs_compat.load_file goal_path);
          check string "rejected retry leaves proof unchanged" before_ledger (Fs_compat.load_file ledger_path);
          check int "rejected retry does not wake verification" 0 !wakes)
          [None; Some ["task:retry-evidence"]]))
    ["reopen"; "drop"; "pause"; "block"]
;;

(* An initial request bound to the Executing Goal it read is refused once
   another actor created a proof request, including a verdict whose phase
   write is pending. *)
let test_initial_request_refuses_a_new_verifying_goal () =
  List.iter (fun outcome ->
    with_workspace @@ fun config ->
    let ctx = workspace_ctx config in
    let goal_id = create_goal ctx "Initial request races verification" in
    let Goal_store.Criterion { revision; _ } = current_criterion config goal_id in
    ignore (must_succeed "another actor requests completion"
      (transition ctx goal_id "request_complete"));
    (match outcome with
     | None -> ()
     | Some proof_outcome ->
       let request_id, criterion = proof_identity config goal_id in
       (match Goal_verification.record_proof_verdict config ~goal_id
                (verdict ~request_id ~criterion proof_outcome) with
        | Ok _ -> () | Error detail -> fail detail));
    check string "the current Goal is verifying" "verifying" (stored_phase config goal_id);
    let goal_path = Goal_store.goals_path config in
    let ledger_path = Goal_verification.verifications_path config in
    let before_goal = Fs_compat.load_file goal_path in
    let before_ledger = Fs_compat.load_file ledger_path in
    let before_events = goal_events_text config in
    let wakes = ref 0 in
    let old = Atomic.exchange Workspace_hooks.goal_verification_pending_fn
      (fun _ ~goal_id:_ -> incr wakes) in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_pending_fn old)
      (fun () ->
        List.iter (fun evidence_refs ->
          let answer = request_complete_bound ctx ~goal_id ?evidence_refs
              [ "phase", `String "executing"; "criterion_revision", `String revision ] in
          let error = must_fail "stale initial request" answer in
          check string "current verifying phase is a conflict" "conflict" (json_state error ["error_code"]);
          check string "Goal is unchanged" before_goal (Fs_compat.load_file goal_path);
          check string "pending request or committed verdict is unchanged" before_ledger
            (Fs_compat.load_file ledger_path);
          check string "no new Goal event is emitted" before_events (goal_events_text config);
          check int "verification is not woken" 0 !wakes)
          [None; Some ["task:retry-evidence"]]))
    [None; Some Goal_verification.Proven;
     Some (Goal_verification.Refuted {reason="target not met"})]
;;

let test_verifying_repeat_preserves_terminal_evidence_contract () =
  List.iter (fun confirmed ->
    with_workspace @@ fun config ->
    let ctx = workspace_ctx config in
    let goal_id = create_goal ctx "Retry races a proven Goal" in
    ignore (must_succeed "initial request" (transition ctx goal_id "request_complete"));
    ignore (must_succeed "intervening proof" (verifier_transition config goal_id
      Workspace_goals.Proof_proven "actual proof"));
    if confirmed then begin
      let verdict = match (ledger_record config goal_id).completion with
        | Goal_verification.Proof_proven verdict -> verdict
        | Goal_verification.Completion_idle | Goal_verification.Proof_pending _
        | Goal_verification.Proof_refuted _ | Goal_verification.Human_confirmed _ ->
            fail "expected proven verdict" in
      let Goal_store.Criterion { revision; _ } = verdict.criterion in
      (match Workspace_goals.confirm_completion config ~goal_id ~operator_id:"operator"
               ~request_id:verdict.request_id ~verification_run_id:verdict.verification_run_id
               ~criterion_revision:revision with
       | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error))
    end;
    let goal_path = Goal_store.goals_path config in
    let ledger_path = Goal_verification.verifications_path config in
    let before_goal = Fs_compat.load_file goal_path in
    let before_ledger = Fs_compat.load_file ledger_path in
    let wakes = ref 0 in
    let old = Atomic.exchange Workspace_hooks.goal_verification_pending_fn
      (fun _ ~goal_id:_ -> incr wakes) in
    Fun.protect ~finally:(fun () -> Atomic.set Workspace_hooks.goal_verification_pending_fn old)
      (fun () ->
        let rejected = dispatch ctx ~name:"masc_goal_transition"
            [ "goal_id", `String goal_id; "action", `String "request_complete"
            ; "evidence_refs", `List [ `String "task:retry-evidence" ] ]
          |> must_fail "terminal Goal rejects unconsumed evidence" in
        check string "evidence cannot be silently dropped" "precondition_failed"
          (json_state rejected ["error_code"]);
        check string "evidence refusal preserves Goal" before_goal (Fs_compat.load_file goal_path);
        check string "evidence refusal preserves proof" before_ledger (Fs_compat.load_file ledger_path);
        let accepted = transition ctx goal_id "request_complete"
          |> must_succeed "terminal Goal remains a no-op" in
        check bool "no evidence permits an already-complete response" true (json_bool accepted ["noop"]);
        check string "response uses the current Goal phase"
          (if confirmed then "completed" else "awaiting_confirmation") (json_state accepted ["phase"]);
        check string "terminal no-op preserves proof" before_ledger (Fs_compat.load_file ledger_path);
        check int "terminal no-op does not wake verification" 0 !wakes))
    [false; true]
;;

(* The scan's first reconciliation and its recovery use separate Goal locks.
   A verifier can commit a verdict between them while the phase write fails. *)
let test_recovery_reconciles_a_verdict_committed_after_the_scan () =
  List.iter (fun via_request ->
  List.iter (fun outcome ->
    with_workspace @@ fun config ->
    let ctx = workspace_ctx config in
    let goal_id = create_goal ctx "Verdict arrives before recovery" in
    ignore (must_succeed "initial request" (transition ctx goal_id "request_complete"));
    (match Workspace_goals.reconcile_committed_proof config ~goal_id with
     | Ok Workspace_goals.No_committed_proof -> ()
     | Ok (Workspace_goals.Reconciled _ | Workspace_goals.Reconciliation_not_needed _)
     | Error _ -> fail "the first scan must see no committed verdict");
    let request_id, criterion = proof_identity config goal_id in
    (match Goal_verification.record_proof_verdict config ~goal_id
             (verdict ~request_id ~criterion outcome) with
     | Ok _ -> () | Error detail -> fail detail);
    let ledger_path = Goal_verification.verifications_path config in
    let before_ledger = Fs_compat.load_file ledger_path in
    (if via_request then (
       ignore (must_succeed "current committed verdict is reconciled"
         (transition ctx goal_id "request_complete"));
       match (ledger_record config goal_id).completion with
       | Goal_verification.Proof_proven stored | Goal_verification.Proof_refuted stored ->
         check string "request keeps the existing verdict" request_id stored.request_id
       | Goal_verification.Completion_idle | Goal_verification.Proof_pending _ | Goal_verification.Human_confirmed _ ->
         fail "request replaced the committed verdict")
     else
       match Workspace_goals.recover_current_proof config ~goal_id with
       | Ok false -> ()
       | Ok true -> fail "a committed verdict must not enqueue another review"
       | Error error -> fail (Goal_store.write_error_to_string error));
    check string "the original verdict is not replaced" before_ledger (Fs_compat.load_file ledger_path);
    check string "the Goal follows the committed verdict"
      (match outcome with Goal_verification.Proven -> "awaiting_confirmation"
       | Goal_verification.Refuted _ -> "executing") (stored_phase config goal_id);
    let events = goal_events_text config in
    check bool "the normal proof event names the committed request" true
      (String_util.contains_substring events request_id);
    (match Workspace_goals.recover_current_proof config ~goal_id with
     | Ok false -> ()
     | Ok true -> fail "a reconciled Goal must not enqueue review"
     | Error error -> fail (Goal_store.write_error_to_string error));
    check string "recovery does not duplicate the proof event" events (goal_events_text config);
    check string "repeated recovery preserves the original verdict" before_ledger
      (Fs_compat.load_file ledger_path))
    [Goal_verification.Proven; Goal_verification.Refuted {reason="target not met"}])
    [false; true]
;;

let test_transition_refuses_a_different_workspace () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Workspace-bound transition" in
  ignore (must_fail "other workspace is refused"
    (dispatch ctx ~name:"masc_goal_transition"
       ["goal_id", `String goal_id; "action", `String "request_complete";
        "expected_workspace", `Assoc ["base_path", `String "/different-workspace";
          "masc_root", `String "/different-workspace/.masc"]]));
  check string "the Goal has not changed" "executing" (stored_phase config goal_id)
;;

let test_goal_cache_scope_tracks_the_resolved_store () =
  let base = temp_dir () in
  let first = Filename.concat base "first" and second = Filename.concat base "second" in
  let link = Filename.concat base ".masc" in
  (* [rm_rf] classifies with [lstat], so the link is removed as a link and the
     [first]/[second] targets it points at stay inside [base] too. Nothing here
     has to unlink it first, and no leftover depends on that ordering. *)
  Fun.protect ~finally:(fun () -> rm_rf base)
    (fun () ->
      Unix.mkdir first 0o755;
      Unix.mkdir second 0o755;
      Unix.symlink first link;
      let config = Workspace.default_config base in
      let old_scope = Server_dashboard_http.goal_cache_scope ~config in
      Unix.unlink link;
      Unix.symlink second link;
      let new_scope = Server_dashboard_http.goal_cache_scope ~config in
      check bool "changing the store root changes the cache scope" false (String.equal old_scope new_scope))
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
       (let request_id, criterion = proof_identity config goal_id in
        verdict ~request_id ~criterion ~evidence:"artifact inspected before crash" Goal_verification.Proven)
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
  check string "the committed proof converges to completed" "awaiting_confirmation"
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
    (match observation.Keeper_world_observation.active_goals with
     | Ok ids -> ids
     | Error unavailable -> fail (Goal_store.unavailable_to_string unavailable));
  (* The subject here is how a [Verifying] goal renders, not which goals a
     turn is given: the summary is stated so the proof-pending mark is what
     the check depends on. The mark rides the Goals Awaiting Proof layer, not
     the Active Goals row (RFC-0491 §3.3). *)
  let summaries =
    [ { Keeper_unified_prompt.summary_goal_id = goal_id
      ; summary_title = "Goal under proof"
      ; summary_priority = 3
      ; summary_created_at = "2026-09-02T01:00:00Z"
      ; summary_criterion = None
      ; summary_review_note = None
      ; summary_measurement = Ok None
      ; summary_phase = Some Goal_phase.Verifying
      ; summary_held_task_link = Keeper_unified_prompt.Not_served_by_held_task
      }
    ]
  in
  let { Keeper_unified_prompt.world_state; _ } =
    Keeper_unified_prompt.build_prompt
      ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~active_goal_summaries:(Ok summaries)
      ~observation
      ()
  in
  check bool "the world state names the goal" true
    (String_util.contains_substring world_state goal_id);
  check bool "with the proof-pending mark" true
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

let ledger_bytes config =
  In_channel.with_open_bin (Goal_verification.verifications_path config)
    In_channel.input_all
;;

let test_stale_proof_request_cannot_consume_revised_criterion () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "A revised measurement needs its own proof" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let old_request, old_criterion = proof_identity config goal_id in
  ignore (must_succeed "change target"
    (dispatch ctx ~name:"masc_goal_upsert"
      [ "id", `String goal_id; "target_value", `String "300" ]));
  let criterion = current_criterion config goal_id in
  (match Goal_verification.mark_proof_pending config ~goal_id ~criterion with
   | Ok _ -> () | Error detail -> fail detail);
  let new_request, _ = proof_identity config goal_id in
  check bool "revision gets a new proof request" false
    (String.equal old_request new_request);
  let before = ledger_bytes config in
  let stale = verdict ~request_id:old_request ~criterion:old_criterion Goal_verification.Proven in
  (match Goal_verification.record_proof_verdict config ~goal_id stale with
   | Error _ -> () | Ok _ -> fail "old approval consumed a newer request");
  check string "rejection preserves all ledger bytes" before (ledger_bytes config);
  check string "changed criterion returns to execution" "executing" (stored_phase config goal_id)
;;

(* A criterion edit takes a Verifying goal back to Executing. That move goes
   into goal_events.jsonl like every other phase move, naming the phase it
   left and why. *)
let goal_phase_events config =
  let path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  if not (Sys.file_exists path) then []
  else
    In_channel.with_open_bin path In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun line -> String.trim line <> "")
    |> List.map Yojson.Safe.from_string
    |> List.filter (fun event ->
      Yojson.Safe.Util.member "event_type" event = `String "goal_phase")
;;

let test_criterion_edit_records_its_phase_move () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "A phase move by edit is recorded" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  ignore (must_succeed "change target"
    (dispatch ctx ~name:"masc_goal_upsert"
      [ "id", `String goal_id; "target_value", `String "300" ]));
  check string "changed criterion returns to execution" "executing"
    (stored_phase config goal_id);
  let edit_moves =
    List.filter
      (fun event ->
        let payload = Yojson.Safe.Util.member "payload" event in
        Yojson.Safe.Util.member "goal_id" event = `String goal_id
        && Yojson.Safe.Util.member "cause" payload = `String "criterion_edit")
      (goal_phase_events config)
  in
  match edit_moves with
  | [ event ] ->
    let payload = Yojson.Safe.Util.member "payload" event in
    check string "the phase it moved to" "executing"
      Yojson.Safe.Util.(payload |> member "phase" |> to_string);
    check string "the phase it left" "verifying"
      Yojson.Safe.Util.(payload |> member "previous_phase" |> to_string)
  | moves -> failf "expected one criterion_edit phase event, got %d" (List.length moves)
;;

let test_criterion_edit_on_executing_goal_records_no_phase_move () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "An edit that moves nothing records nothing" in
  ignore (must_succeed "change target"
    (dispatch ctx ~name:"masc_goal_upsert"
      [ "id", `String goal_id; "target_value", `String "300" ]));
  check int "no goal_phase event" 0 (List.length (goal_phase_events config))
;;

let test_proof_replay_preserves_evidence_and_rejects_different_run () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "An exact proof can be delivered twice" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let request_id, criterion = proof_identity config goal_id in
  let proof = { (verdict ~request_id ~criterion Goal_verification.Proven) with
    recorded_at = "2026-09-09T00:00:00Z" } in
  let commit proof = Goal_verification.record_proof_verdict config ~goal_id proof in
  (match commit proof with Ok _ -> () | Error detail -> fail detail);
  let before = ledger_bytes config in
  (match commit { proof with recorded_at = "2026-09-09T00:01:00Z" } with
   | Ok { completion = Goal_verification.Proof_proven retained; _ } ->
     check string "replay retains original commit time" proof.recorded_at retained.recorded_at
   | Ok _ -> fail "replay lost proven evidence" | Error detail -> fail detail);
  check string "replay never rewrites ledger bytes" before (ledger_bytes config);
  (match commit { proof with verification_run_id = "another-review-run" } with
   | Error _ -> () | Ok _ -> fail "same outcome from another run replaced the proof");
  check string "conflicting run preserves ledger bytes" before (ledger_bytes config)
;;

let test_recovered_goal_cannot_authorize_edits_or_deletion () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Primary authority for criterion edits" in
  let path = Goal_store.goals_path config in
  let mirror = Fs_compat.load_file (path ^ ".last-good") in
  let refuse_changes () =
    (match Goal_store.upsert_goal_with_events ~actor:"test" config ~id:goal_id ~target_value:"300" () with
     | Error _ -> () | Ok _ -> fail "mirror authorized a changed criterion");
    (match Goal_store.transact_goal config ~goal_id
       (fun goal -> Ok ({ goal with phase = Goal_phase.Dropped }, ())) with
     | Error _ -> () | Ok _ -> fail "mirror authorized a phase change");
    (match Goal_store.delete_goal config ~goal_id with
     | Error _ -> () | Ok _ -> fail "mirror authorized Goal deletion")
  in
  Fs_compat.save_file path "broken-primary";
  refuse_changes ();
  check string "corrupt primary survives refused mutations" "broken-primary" (Fs_compat.load_file path);
  Sys.remove path;
  refuse_changes ();
  check bool "missing primary is not reconstructed by a mutation" false (Sys.file_exists path);
  check string "mirror remains untouched" mirror (Fs_compat.load_file (path ^ ".last-good"))
;;

let test_recovery_proof_cannot_authorize_mutation () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Recovery is evidence, not write authority" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let request_id, criterion = proof_identity config goal_id in
  let path = Goal_verification.verifications_path config in
  Out_channel.with_open_bin path (fun ch -> output_string ch "broken-primary");
  (match Goal_verification.get_record_authoritative config ~goal_id with
   | Error _ -> () | Ok _ -> fail "mirror authorized a current-state decision");
  (match Goal_verification.record_proof_verdict config ~goal_id
      (verdict ~request_id ~criterion Goal_verification.Proven) with
   | Error _ -> () | Ok _ -> fail "mirror authorized a proof commit");
  check string "primary failure is not overwritten" "broken-primary" (ledger_bytes config)
;;

let proof_mirror_presence_scenario () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Keep an unresolved proof ledger" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let _, criterion = proof_identity config goal_id in
  let primary = Goal_verification.verifications_path config in
  let mirror = primary ^ ".last-good" in
  let primary_saved = primary ^ ".saved-for-test" in
  let mirror_saved = mirror ^ ".saved-for-test" in
  let before_primary = Fs_compat.load_file primary in
  let before_mirror = Fs_compat.load_file mirror in
  Unix.rename primary primary_saved;
  Unix.rename mirror mirror_saved;
  let refuse label =
    (match Goal_verification.get_record_authoritative config ~goal_id with
     | Error _ -> () | Ok _ -> fail (label ^ ": mirror was treated as no prior proof"));
    (match Goal_verification.bind_review config ~goal_id with
     | Error (Goal_verification.Binding_unavailable _) -> ()
     | Error (Goal_verification.No_current_review _) | Ok _ -> fail (label ^ ": verifier admission did not retain uncertainty"));
    (match Goal_verification.mark_proof_pending config ~goal_id ~criterion with
     | Error _ -> () | Ok _ -> fail (label ^ ": missing primary was overwritten"));
    check bool (label ^ ": no new primary") false (Sys.file_exists primary);
    check string (label ^ ": original primary preserved") before_primary (Fs_compat.load_file primary_saved);
    check string (label ^ ": original mirror preserved") before_mirror (Fs_compat.load_file mirror_saved) in
  let with_entry make f =
    make ();
    Fun.protect ~finally:(fun () -> Unix.unlink mirror) f in
  with_entry (fun () -> Unix.symlink "missing-test-target" mirror) (fun () -> refuse "dangling mirror");
  with_entry (fun () -> Unix.symlink (Filename.basename mirror) mirror) (fun () -> refuse "cyclic mirror");
  with_entry (fun () -> Unix.mkfifo mirror 0o600) (fun () -> refuse "FIFO mirror");
  with_entry (fun () -> Unix.symlink (Filename.basename mirror_saved) mirror) (fun () -> refuse "regular mirror link");
  let with_primary_link target f =
    Unix.symlink target primary;
    Fun.protect ~finally:(fun () -> Unix.unlink primary) (fun () ->
      f ();
      check bool "primary symlink is preserved" true ((Unix.lstat primary).Unix.st_kind = Unix.S_LNK);
      check string "primary symlink target is preserved" target (Unix.readlink primary)) in
  with_primary_link "missing-test-target" (fun () -> refuse "dangling primary");
  with_primary_link (Filename.basename primary) (fun () -> refuse "cyclic primary");
  let memory_backend = Backend.Memory.create () in
  let memory = {config with Workspace_utils.backend = Workspace_utils.Memory memory_backend} in
  let key = match Workspace_utils.key_of_path memory mirror with
    | Some key -> key | None -> fail "memory mirror is outside the workspace" in
  (match Backend.Memory.set memory_backend key before_mirror with
   | Ok () -> () | Error error -> fail (Backend_types.show_error error));
  (match Goal_verification.get_record_authoritative memory ~goal_id with
   | Error _ -> () | Ok _ -> fail "memory mirror authorized an empty primary");
  check string "memory check leaves the original primary alone" before_primary (Fs_compat.load_file primary_saved)
;;

(* #47589: a FIFO at the primary path has no writer. Before the ledger read
   took the kind from the opened descriptor, the open waited for one while the
   ledger lock was held; the scenario runs under the process hang guard. *)
let proof_primary_fifo_scenario () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Keep a proof ledger behind a FIFO" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let request_id, criterion = proof_identity config goal_id in
  let primary = Goal_verification.verifications_path config in
  let mirror = primary ^ ".last-good" in
  let primary_saved = primary ^ ".saved-for-test" in
  let before_primary = Fs_compat.load_file primary in
  let before_mirror = Fs_compat.load_file mirror in
  Unix.rename primary primary_saved;
  Unix.mkfifo primary 0o600;
  Fun.protect ~finally:(fun () -> Unix.unlink primary) (fun () ->
    (match Goal_verification.get_record_authoritative config ~goal_id with
     | Error _ -> () | Ok _ -> fail "a FIFO primary was read as a ledger");
    (match Goal_verification.bind_review config ~goal_id with
     | Error (Goal_verification.Binding_unavailable _) -> ()
     | Error (Goal_verification.No_current_review _) | Ok _ ->
       fail "verifier admission did not retain uncertainty");
    (match Goal_verification.mark_proof_pending config ~goal_id ~criterion with
     | Error _ -> () | Ok _ -> fail "a FIFO primary admitted a new proof request");
    (match Goal_verification.record_proof_verdict config ~goal_id
        (verdict ~request_id ~criterion Goal_verification.Proven) with
     | Error _ -> () | Ok _ -> fail "a FIFO primary admitted a proof commit");
    check bool "the FIFO is not replaced" true
      ((Unix.lstat primary).Unix.st_kind = Unix.S_FIFO));
  check string "original primary preserved" before_primary (Fs_compat.load_file primary_saved);
  check string "mirror preserved" before_mirror (Fs_compat.load_file mirror);
  Unix.rename primary_saved primary;
  let link_target = primary ^ ".link-target" in
  Unix.rename primary link_target;
  Unix.symlink (Filename.basename link_target) primary;
  match Goal_verification.get_record_authoritative config ~goal_id with
  | Ok (Some _) -> ()
  | Ok None -> fail "a link to the regular ledger lost its record"
  | Error detail -> fail ("a link to the regular ledger was refused: " ^ detail)
;;

let run_scenario_guarded ~flag ~label () =
  let program = "import os,signal,subprocess,sys\n" ^
    "child=subprocess.Popen([sys.argv[1],sys.argv[2]],start_new_session=True)\n" ^
    "try: code=child.wait(timeout=40)\n" ^
    "except subprocess.TimeoutExpired:\n" ^
    " os.killpg(child.pid,signal.SIGKILL); child.wait(); sys.exit(124)\n" ^
    "sys.exit(code if code>=0 else 128-code)\n" in
  let executable = Unix.realpath Sys.executable_name in
  let pid = Unix.create_process "python3" [|"python3"; "-c"; program; executable; flag|]
      Unix.stdin Unix.stdout Unix.stderr in
  (* A signal that arrives during the wait ends it with EINTR. On macOS the
     full suite reaches this wait with a handler installed by earlier cases,
     and the wait was interrupted on every run; the case alone was not. *)
  let rec exit_status () =
    match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> exit_status ()
  in
  match exit_status () with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED 124 -> fail (label ^ " exceeded its process hang guard")
  | Unix.WEXITED code -> fail (Printf.sprintf "%s exited %d" label code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    fail (Printf.sprintf "%s ended with signal %d" label signal)
;;

let proof_mirror_presence_flag = "--proof-mirror-presence"
let proof_primary_fifo_flag = "--proof-primary-fifo"

let test_proof_mirror_presence_guarded =
  run_scenario_guarded ~flag:proof_mirror_presence_flag ~label:"Goal mirror presence check"
;;

let test_proof_primary_fifo_guarded =
  run_scenario_guarded ~flag:proof_primary_fifo_flag ~label:"Goal proof FIFO primary check"
;;

let test_memory_proof_cannot_supply_authority () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Keep the durable proof authority" in
  let executing_goal_id = create_goal ctx "Do not capture evidence without proof authority" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let request_id, criterion = proof_identity config goal_id in
  let primary = Goal_verification.verifications_path config in
  let mirror = primary ^ ".last-good" in
  let primary_before = Fs_compat.load_file primary in
  let mirror_before = Fs_compat.load_file mirror in
  let events_before = goal_events_text config in
  let backend = Backend.Memory.create () in
  let memory = { config with Workspace_utils.backend = Workspace_utils.Memory backend } in
  let key path = match Workspace_utils.key_of_path memory path with
    | Some key -> key | None -> fail "proof path is outside the workspace" in
  let primary_key = key primary and mirror_key = key mirror in
  let expect_unavailable label = function
    | Ok _ -> fail (label ^ ": Memory supplied proof authority")
    | Error detail ->
      check bool (label ^ ": diagnostic names the backend") true
        (String_util.contains_substring detail "Memory backend cannot safely provide proof authority") in
  let expect_missing key = match Backend.Memory.get backend key with
    | Error (Backend_types.NotFound _) -> ()
    | Error ((Backend_types.AlreadyExists _ | Backend_types.IOError _ | Backend_types.InvalidKey _) as error) ->
      fail (Backend_types.show_error error)
    | Ok _ -> fail "refused request changed the Memory backend" in
  let expect_local_unchanged () =
    check string "local primary is preserved" primary_before (Fs_compat.load_file primary);
    check string "local recovery mirror is preserved" mirror_before (Fs_compat.load_file mirror);
    check string "reopen audit is not appended" events_before (goal_events_text config);
    check string "the Goal stays verifying" "verifying" (stored_phase config goal_id);
    check string "the other Goal stays executing" "executing" (stored_phase config executing_goal_id) in
  expect_unavailable "empty Memory authoritative read"
    (Goal_verification.get_record_authoritative memory ~goal_id);
  expect_unavailable "empty Memory pending request"
    (Goal_verification.mark_proof_pending memory ~goal_id ~criterion);
  (let refused = must_fail "evidence capture ran before the Memory backend refusal"
     (dispatch (workspace_ctx memory) ~name:"masc_goal_transition"
        [ "goal_id", `String executing_goal_id; "action", `String "request_complete"
        ; "evidence_refs", `List [ `String "board:missing-proof-source" ] ]) in
   check string "backend refusal is an internal error" "internal_error" (json_state refused ["error_code"]);
   check bool "backend refusal precedes evidence capture" true
     (String_util.contains_substring (Yojson.Safe.to_string refused)
        "Memory backend cannot safely provide proof authority"));
  (match Goal_verification.bind_review memory ~goal_id with
   | Error (Goal_verification.Binding_unavailable _) -> ()
   | Error (Goal_verification.No_current_review _) | Ok _ ->
     fail "unavailable Memory proof did not retain the review binding");
  (match Workspace_goals.recover_current_proof memory ~goal_id with
   | Error _ -> () | Ok _ -> fail "Memory recovered a proof request");
  expect_missing primary_key;
  expect_missing mirror_key;
  expect_local_unchanged ();
  (match Backend.Memory.set backend primary_key primary_before with
   | Ok () -> () | Error error -> fail (Backend_types.show_error error));
  (match Backend.Memory.set backend mirror_key mirror_before with
   | Ok () -> () | Error error -> fail (Backend_types.show_error error));
  let before_commit_called = ref false in
  let before_commit () = before_commit_called := true; Ok () in
  expect_unavailable "Memory verdict"
    (Goal_verification.record_proof_verdict ~before_commit memory ~goal_id
       (verdict ~request_id ~criterion Goal_verification.Proven));
  expect_unavailable "Memory reopen"
    (Goal_verification.reopen_goal memory ~goal_id ~actor:"operator" ~note:None);
  check bool "Memory refusal precedes verdict effects" false !before_commit_called;
  (match Backend.Memory.get backend primary_key, Backend.Memory.get backend mirror_key with
   | Ok primary_after, Ok mirror_after ->
     check string "Memory primary is preserved" primary_before primary_after;
     check string "Memory mirror is preserved" mirror_before mirror_after
   | Error _, _ | _, Error _ -> fail "Memory proof snapshot disappeared");
  expect_local_unchanged ();
  (match Goal_verification.record_proof_verdict config ~goal_id
           (verdict ~request_id ~criterion Goal_verification.Proven) with
   | Ok _ -> () | Error detail -> fail detail)
;;


(* {1 The caller's step before a passing verdict is written} *)

let verifier_transition_with_step ~before_proof_commit config goal_id decision evidence =
  let request_id, criterion = proof_identity config goal_id in
  Workspace_goals.commit_verifier_decision
    ~before_proof_commit
    ~tool_name:"goal_verifier_commit"
    ~start_time:(Tool_timing.start ())
    config
    ~goal_id
    ~verification_run_id:"goal-verifier-test-run"
    ~request_id
    ~criterion
    ~decision
    ~evidence
;;

let goal_in_verifying config title =
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx title in
  ignore (must_succeed "request_complete" (transition ctx goal_id "request_complete"));
  goal_id
;;

let test_step_sees_the_passing_verdict_before_it_is_written () =
  with_workspace
  @@ fun config ->
  let goal_id = goal_in_verifying config "Step sees the verdict" in
  let request_id, _ = proof_identity config goal_id in
  let seen = ref [] in
  let step (goal : Goal_store.goal) (verdict : Goal_verification.verdict) =
    let request_still_pending =
      match (ledger_record config goal_id).completion with
      | Goal_verification.Proof_pending _ -> true
      | Goal_verification.Completion_idle | Goal_verification.Proof_proven _
      | Goal_verification.Proof_refuted _ | Goal_verification.Human_confirmed _ -> false
    in
    seen
    := ( goal.Goal_store.id
       , verdict.Goal_verification.request_id
       , verdict.Goal_verification.outcome
       , request_still_pending
       , Goal_phase.to_string goal.Goal_store.phase )
       :: !seen;
    Ok ()
  in
  let committed =
    must_succeed
      "proven"
      (verifier_transition_with_step
         ~before_proof_commit:step
         config
         goal_id
         Workspace_goals.Proof_proven
         "artifact:proof")
  in
  check string "the Goal moved" "awaiting_confirmation" (json_state committed [ "goal"; "phase" ]);
  match !seen with
  | [ (id, seen_request, outcome, request_still_pending, phase) ] ->
    check string "names the Goal" goal_id id;
    check string "names the pending request" request_id seen_request;
    check bool "is a passing verdict" true (outcome = Goal_verification.Proven);
    check bool "the ledger still holds the pending request" true request_still_pending;
    check string "the Goal is still Verifying" "verifying" phase
  | calls -> fail (Printf.sprintf "expected one call, got %d" (List.length calls))
;;

let test_a_refusing_step_leaves_the_proof_pending () =
  with_workspace
  @@ fun config ->
  let goal_id = goal_in_verifying config "Step refuses" in
  let request_id, _ = proof_identity config goal_id in
  let refusal =
    verifier_transition_with_step
      ~before_proof_commit:(fun _ _ -> Error "candle ledger unavailable")
      config
      goal_id
      Workspace_goals.Proof_proven
      "artifact:proof"
  in
  ignore (must_fail "the step refuses" refusal);
  check bool "the refusal reaches the caller" true
    (String_util.contains_substring (Tool_result.message refusal) "candle ledger unavailable");
  check string "the Goal stays in Verifying" "verifying" (stored_phase config goal_id);
  (match (ledger_record config goal_id).completion with
   | Goal_verification.Proof_pending pending ->
     check string "the same request is still pending" request_id pending.request_id
   | Goal_verification.Completion_idle | Goal_verification.Proof_proven _
   | Goal_verification.Proof_refuted _ | Goal_verification.Human_confirmed _ ->
     fail "a refused step must not consume the request");
  let committed =
    must_succeed
      "the same verdict commits once nothing refuses"
      (verifier_transition config goal_id Workspace_goals.Proof_proven "artifact:proof")
  in
  check string "the Goal moved" "awaiting_confirmation" (json_state committed [ "goal"; "phase" ])
;;

let test_the_step_does_not_run_for_a_refutation () =
  with_workspace
  @@ fun config ->
  let goal_id = goal_in_verifying config "Step skipped for a refutation" in
  let calls = ref 0 in
  let refuted =
    must_succeed
      "refuted"
      (verifier_transition_with_step
         ~before_proof_commit:(fun _ _ -> incr calls; Error "must not run")
         config
         goal_id
         (Workspace_goals.Proof_refuted { reason = "metric moved under the claim" })
         "coverage run attached")
  in
  check int "the step did not run" 0 !calls;
  check string "back to executing" "executing" (json_state refuted [ "goal"; "phase" ])
;;

let test_the_step_does_not_run_again_for_a_replayed_verdict () =
  with_workspace
  @@ fun config ->
  let goal_id = goal_in_verifying config "Step skipped for a replay" in
  let calls = ref 0 in
  let commit () =
    must_succeed
      "proven"
      (verifier_transition_with_step
         ~before_proof_commit:(fun _ _ -> incr calls; Ok ())
         config
         goal_id
         Workspace_goals.Proof_proven
         "artifact:proof")
  in
  ignore (commit ());
  check int "the first commit ran the step" 1 !calls;
  ignore (commit ());
  check int "the replay did not" 1 !calls
;;

let notification_store config = match Goal_store.load_source config with
  | Goal_store.Available state -> state
  | Goal_store.Uninitialized -> fail "Goal store is absent"
  | Goal_store.Unavailable error -> fail (Goal_store.unavailable_to_string error)

let persist_notification_keeper config name =
  let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String name]) with
    | Ok value -> value | Error detail -> fail detail in
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> () | Error detail -> fail detail

let notification_rows config keeper request_id =
  match Keeper_chat_store.load_all_result ~base_dir:config.Workspace.base_path ~keeper_name:keeper with
  | Error error -> fail (Keeper_chat_store.strict_decode_error_to_string error)
  | Ok rows -> List.filter (fun (row : Keeper_chat_store.chat_message) ->
      row.external_message_id = Some request_id) rows

let notification_message_count config request_id =
  Workspace.get_all_messages_raw config ~since_seq:0
  |> List.filter (fun (message : Masc_domain.message) -> message.request_id = request_id)
  |> List.length

let proof_audit_count config goal_id =
  goal_phase_events config |> List.filter (fun event ->
    Yojson.Safe.Util.(event |> member "goal_id" |> to_string) = goal_id
    && Json_util.get_string (Yojson.Safe.Util.member "payload" event) "verification_run_id"
       = Some "goal-verifier-test-run") |> List.length

let test_proof_effect_delivery_recovers_audit_and_partial_recipients () =
  List.iter (fun (decision, expected_phase) ->
    List.iter (fun fail_after_append ->
      with_workspace @@ fun config ->
      let ctx = workspace_ctx config in
      let goal_id = create_goal ctx "Persisted @beta proof title" in
      ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
      let extra_recipients = ["verifier_exact"; String.make 65 'k'; ".reviewer"] in
      List.iter (persist_notification_keeper config) (["alpha"; "beta"] @ extra_recipients);
      (* These persisted recipients have never entered the live registry. *)
      let host = Server_bootstrap_loops.For_testing.goal_notification_backend in
      let fail_beta = ref true in
      let backend : Goal_delivery.backend = {host with project=(fun ~config ~delivery ~recipient ->
        if recipient = "beta" && !fail_beta && not fail_after_append then Error "fixture transcript unavailable"
        else match host.project ~config ~delivery ~recipient with
          | Error _ as error -> error
          | Ok () when recipient = "beta" && !fail_beta -> Error "fixture lost acknowledgement after append"
          | Ok () -> Ok ())} in
      ignore (Goal_delivery.For_testing.replace_backend (Some backend));
      let fanouts = ref 0 in
      let old_handler = Workspace_broadcast.For_testing.replace_on_broadcast_mention
        (fun _ -> incr fanouts; Workspace_broadcast.Passive) in
      Fun.protect ~finally:(fun () -> Workspace_broadcast.set_on_broadcast_mention old_handler) (fun () ->
        let audit = Filename.concat (Workspace.masc_dir config) "goal_events.jsonl" in
        let saved_audit = audit ^ ".fixture-saved" in
        Unix.rename audit saved_audit;
        Unix.mkdir audit 0o700;
        let calls = ref 0 in
        let commit () = verifier_transition_with_step
          ~before_proof_commit:(fun _ _ -> incr calls; Ok ()) config goal_id decision "measured @beta evidence" in
        let first = must_succeed "proof commits despite unavailable audit/recipient" (commit ()) in
        check string "phase is committed" expected_phase (stored_phase config goal_id);
        check string "deferred effects are explicit" "deferred" (json_state first ["effect_delivery";"status"]);
        let pending = notification_store config in
        check int "audit intent survives failure" 1 (List.length pending.pending_events);
        let notice = match pending.pending_notifications with [notice] -> notice | _ -> fail "expected one notice" in
        (match notice.delivery with
         | Goal_store.Pending_recipients remaining ->
             check (list string) "only failed recipient remains" ["beta"] (remaining :> string list)
         | Awaiting_recipients -> fail "snapshot did not commit");
        check int "healthy recipient is not blocked by failed audit" 1 (List.length (notification_rows config "alpha" notice.notification_id));
        check int "failure window has expected durable beta rows" (if fail_after_append then 1 else 0)
          (List.length (notification_rows config "beta" notice.notification_id));
        (match notification_rows config "verifier_exact" notice.notification_id with
         | [row] -> check bool "same spelling cannot turn an external verifier into the recipient Keeper" true
             (match row.speaker with Some {speaker_authority=Keeper_chat_store.External;_} -> true | _ -> false)
         | _ -> fail "system verifier name collision dropped a legitimate recipient");
        List.iter (fun keeper -> check int "every valid persisted Keeper name receives the notice" 1
          (List.length (notification_rows config keeper notice.notification_id))) extra_recipients;
        check int "workspace message is committed once" 1 (notification_message_count config notice.notification_id);
        ignore (must_succeed "exact verdict replay" (commit ()));
        check int "proof precommit is not rerun on effect retry"
          (match decision with Workspace_goals.Proof_proven -> 1 | Proof_refuted _ -> 0) !calls;
        check int "literal mentions never enter synchronous fanout/wake" 0 !fanouts;
        (* Repair audit and model append-before-ack loss using the exact outbox row. *)
        Unix.rmdir audit; Unix.rename saved_audit audit;
        (match Goal_store.append_audit_event config (Goal_store.pending_event_to_yojson (List.hd pending.pending_events)) with
         | Ok () -> () | Error detail -> fail detail);
        fail_beta := false;
        (* A restarted host reads the durable remaining set, not a changed roster. *)
        ignore (Goal_delivery.For_testing.replace_backend (Some {host with
          snapshot=(fun ~config:_ -> fail "persisted snapshot must not be recaptured")}));
        (match Goal_delivery.flush config with Ok () -> () | Error detail -> fail detail);
        (match Goal_delivery.flush config with Ok () -> () | Error detail -> fail detail);
        check int "audit append before acknowledgement is deduplicated" 1 (proof_audit_count config goal_id);
        check int "healthy transcript remains exactly once" 1 (List.length (notification_rows config "alpha" notice.notification_id));
        check int "failed transcript eventually arrives exactly once" 1 (List.length (notification_rows config "beta" notice.notification_id));
        check int "message remains exactly once" 1 (notification_message_count config notice.notification_id);
        check int "all notification obligations settled" 0 (List.length (notification_store config).pending_notifications);
        (* Reintroduce the captured obligation as a crash after delivery but
           before Goal acknowledgement. The sink's real identity deduplicates. *)
        let settled = notification_store config in
        Goal_store.write_state config {settled with pending_notifications=[notice]};
        (match Goal_delivery.flush config with Ok () -> () | Error detail -> fail detail);
        check int "lost acknowledgement does not duplicate transcript" 1
          (List.length (notification_rows config "beta" notice.notification_id))))
      [false; true])
    [Workspace_goals.Proof_proven, "awaiting_confirmation";
     Workspace_goals.Proof_refuted {reason="target not observed"}, "executing"]
;;

let test_maintenance_mention_delivery_proceeds_while_goal_delivery_is_locked () =
  with_workspace @@ fun config ->
  let module Recovery = Server_maintenance_delivery_recovery in
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Original maintenance proof" in
  ignore (must_succeed "request proof" (transition ctx goal_id "request_complete"));
  (* Retain an actual committed proof notification before its host is present. *)
  ignore (Goal_delivery.For_testing.replace_backend None);
  ignore (must_succeed "commit proof with deferred delivery"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "original evidence"));
  let notice = match (notification_store config).pending_notifications with
    | [notice] -> notice
    | [] | _ :: _ -> fail "expected original pending proof notification" in
  ignore (Goal_delivery.For_testing.replace_backend
    (Some Server_bootstrap_loops.For_testing.goal_notification_backend));
  List.iter (persist_notification_keeper config) ["alpha";"beta"];
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path in
  Fs_compat.mkdir_p keepers_dir;
  let oc = open_out (Filename.concat keepers_dir "beta.toml") in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
    output_string oc
      "[keeper]\ninstructions = \"Maintenance delivery fixture.\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n");
  let previous_handler = Workspace_broadcast.For_testing.replace_on_broadcast_mention
    (fun delivery -> match delivery.Workspace_broadcast.mention with
      | None -> Workspace_broadcast.Passive
      | Some _ -> Workspace_broadcast.Deferred Handler_unavailable) in
  Fun.protect ~finally:(fun () ->
    Workspace_broadcast.set_on_broadcast_mention previous_handler) (fun () ->
    (* Stage the real authoritative message/outbox while its host is absent;
       recovery below uses the production recipient delivery implementation. *)
    let original = match Workspace_broadcast.broadcast ~audience:Fleet_conversation
        config ~from_agent:"operator" ~content:"@beta retain original maintenance request" with
      | Ok delivery -> delivery
      | Error error -> fail (Workspace_broadcast.broadcast_error_to_string error) in
    Workspace_broadcast.set_on_broadcast_mention
      (Server_bootstrap_loops.For_testing.deliver_broadcast_mention
        ~config ~base_path:config.base_path ~is_running:(fun _ -> false)
        ~is_registered_keeper:(fun _ -> false)
        ~wakeup:(fun _ -> fail "stopped recipient must not be woken"));
    let goal_settled, resolve_goal = Eio.Promise.create () in
    let mention_settled, resolve_mention = Eio.Promise.create () in
    let recovery = Recovery.create ~on_settled:(fun ~base_path -> function
      | Recovery.Goal_settled result -> Eio.Promise.resolve resolve_goal (base_path,result)
      | Recovery.Broadcast_settled result -> Eio.Promise.resolve resolve_mention (base_path,result)) () in
    Eio.Switch.run (fun sw ->
      let goal_delivery_lock = Filename.concat (Workspace.masc_dir config)
          "goal-notification-delivery" in
      File_lock_eio.with_lock goal_delivery_lock (fun () ->
        Recovery.pulse ~sw ~config recovery Goal_effects;
        Recovery.pulse ~sw ~config recovery Broadcast_mentions;
        let observed_base, mention_result = Eio.Promise.await mention_settled in
        check string "mention observer retains original workspace" config.base_path observed_base;
        (match mention_result with
         | Error detail -> fail detail
         | Ok report ->
           check (list string) "recipient has no predecessor barrier" [] report.blocked_targets;
           check bool "healthy mention has no global barrier" false report.global_barrier);
        check bool "Goal delivery still waits for its real lock" false
          (Eio.Promise.is_resolved goal_settled);
        check string "proof phase is not delivery progress" "awaiting_confirmation"
          (stored_phase config goal_id);
        (match (notification_store config).pending_notifications with
         | [pending] ->
           check string "locked original notice survives" notice.notification_id pending.notification_id;
           check string "locked original Goal survives" goal_id pending.goal_id
         | [] | _ :: _ -> fail "locked original proof notification changed");
        (match notification_rows config "beta" original.request_id with
         | [row] -> check string "original mention content retained" original.content row.content
         | [] | _ :: _ -> fail "original mention was not delivered exactly once");
        (match Workspace_broadcast.find_broadcast ~request_id:original.request_id
            config ~from_agent:original.from_agent ~content:original.content with
         | Ok (Some delivery) ->
           check int "recovery retains authoritative sequence" original.seq delivery.seq;
           (match delivery.mention_delivery with
            | Workspace_broadcast.Accepted | Already_accepted -> ()
            | Passive | Pending | Deferred _ | Rejected _ -> fail "original mention not acknowledged")
         | Ok None -> fail "original committed message disappeared"
         | Error error -> fail (Workspace_broadcast.broadcast_error_to_string error));
        (* A repeated pulse while the original worker is blocked must leave
           that worker owning the reservation, rather than replacing it. *)
        Recovery.pulse ~sw ~config recovery Goal_effects);
      let observed_base, goal_result = Eio.Promise.await goal_settled in
      check string "Goal observer retains original workspace" config.base_path observed_base;
      match goal_result with
      | Ok () -> ()
      | Error detail -> fail detail);
    check int "Goal outbox acknowledged after original lock release" 0
      (List.length (notification_store config).pending_notifications);
    List.iter (fun keeper ->
      match notification_rows config keeper notice.notification_id with
      | [row] -> check string "original proof content retained" notice.content row.content
      | [] | _ :: _ -> fail "original Goal notice did not reach each snapshotted recipient")
      ["alpha";"beta"];
    (* New rounds reread durable ACKs using the production drains. *)
    let retry = Recovery.create () in
    Eio.Switch.run (fun sw ->
      Recovery.pulse ~sw ~config retry Goal_effects;
      Recovery.pulse ~sw ~config retry Broadcast_mentions);
    check int "fresh mention recovery preserves one original transcript" 1
      (List.length (notification_rows config "beta" original.request_id));
    List.iter (fun keeper -> check int "fresh proof recovery preserves one original transcript" 1
      (List.length (notification_rows config keeper notice.notification_id))) ["alpha";"beta"])
;;

let test_proof_delivery_survives_reconciliation_and_goal_removal () =
  List.iter (fun recovery -> with_workspace @@ fun config ->
    let ctx = workspace_ctx config in
    let original_title = "Original @beta proof title" in
    let goal_id = create_goal ctx original_title in
    ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
    let request_id, criterion = proof_identity config goal_id in
    let proof = { (verdict ~request_id ~criterion ~evidence:"original measured evidence" Goal_verification.Proven) with
      authority=Masc_domain.System_llm_agent {agent_run_id=Standalone_lane.to_id Standalone_lane.Verifier} } in
    (match Goal_verification.record_proof_verdict config ~goal_id proof with Ok _ -> () | Error detail -> fail detail);
    ignore (Goal_delivery.For_testing.replace_backend None);
    (match recovery with
     | `Scan -> (match Workspace_goals.reconcile_committed_proof config ~goal_id with
         | Ok (Workspace_goals.Reconciled Goal_phase.Awaiting_confirmation) -> ()
         | _ -> fail "scan did not reconcile the committed proof")
     | `Repeat -> ignore (must_succeed "explicit repeat" (transition ctx goal_id "request_complete"))
     | `Commit_retry -> ignore (must_succeed "exact proof-only commit retry"
         (verifier_transition_with_step ~before_proof_commit:(fun _ _ -> fail "committed proof must not rerun its precommit")
           config goal_id Workspace_goals.Proof_proven "original measured evidence")));
    let notice = match (notification_store config).pending_notifications with
      | [notice] -> notice | _ -> fail "reconciliation did not persist one notice" in
    check bool "missing backend is not an empty roster" true (notice.delivery = Goal_store.Awaiting_recipients);
    check int "no publication before snapshot" 0 (notification_message_count config notice.notification_id);
    ignore (must_succeed "rename after commit" (dispatch ctx ~name:"masc_goal_upsert"
      ["id", `String goal_id; "title", `String "Changed title"]));
    (match Goal_store.delete_goal config ~goal_id with
     | Ok _ -> () | Error error -> fail (Goal_store.delete_goal_error_to_string error));
    List.iter (persist_notification_keeper config) ["alpha"; "beta"];
    ignore (Goal_delivery.For_testing.replace_backend (Some Server_bootstrap_loops.For_testing.goal_notification_backend));
    (match Goal_delivery.flush config with Ok () -> () | Error detail -> fail detail);
    check int "deleted Goal still owes original audit" 1 (proof_audit_count config goal_id);
    List.iter (fun keeper -> match notification_rows config keeper notice.notification_id with
      | [row] -> check string "original payload survives rename/delete/restart" notice.content row.content
      | _ -> fail "expected original notification once") ["alpha"; "beta"];
    check bool "message is not reconstructed from current Goal" true
      (String_util.contains_substring notice.content original_title);
    check int "reconciled notification settles" 0 (List.length (notification_store config).pending_notifications))
    [`Scan; `Repeat; `Commit_retry]
;;

let test_roster_read_failure_keeps_the_goal_notification_uncaptured () =
  with_workspace @@ fun config ->
  let ctx = workspace_ctx config in
  let goal_id = create_goal ctx "Roster failure is not an empty fleet" in
  ignore (must_succeed "request" (transition ctx goal_id "request_complete"));
  let root = Workspace.keepers_runtime_dir config in
  if Sys.file_exists root then Unix.rmdir root;
  Fs_compat.save_file root "fixture blocked Keeper directory";
  ignore (must_succeed "proof commits while roster is unreadable"
    (verifier_transition config goal_id Workspace_goals.Proof_proven "target measured"));
  let notice = match (notification_store config).pending_notifications with
    | [notice] -> notice | _ -> fail "roster error discarded the obligation" in
  check bool "failed roster stays uncaptured" true (notice.delivery=Goal_store.Awaiting_recipients);
  check int "roster failure did not publish a zero-recipient message" 0 (notification_message_count config notice.notification_id);
  Sys.remove root;
  persist_notification_keeper config "alpha";
  (match Goal_delivery.flush config with Ok () -> () | Error detail -> fail detail);
  check int "persisted recipient gets the repaired notification" 1
    (List.length (notification_rows config "alpha" notice.notification_id));
  check int "repaired notification settles" 0 (List.length (notification_store config).pending_notifications)
;;

(* A proof request takes its phase from [Goal_phase.decide_transition]: an
   Executing goal enters Verifying and a Verifying one stays, while a goal the
   machine answers with any other phase gets no pending proof. Completed is
   the case that matters: the machine says [Already Completed] there, which is
   not a request for verification. *)
let test_proof_request_follows_the_phase_machine () =
  with_workspace
  @@ fun config ->
  let ctx = workspace_ctx config in
  let goal =
    match Goal_store.upsert_goal_with_events ~actor:"test" config ~title:"proof" ~metric:"m" ~target_value:"1" () with
    | Ok (goal, _, _) -> goal
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  let request () = transition ctx goal.id "request_complete" in
  let phase_after label =
    ignore (must_succeed label (request ()));
    stored_phase config goal.id
  in
  check string "an executing goal enters verifying" "verifying"
    (phase_after "an executing goal refused a proof request");
  check string "a verifying goal stays verifying" "verifying"
    (phase_after "a verifying goal refused a repeated proof request");
  (match
     Goal_store.transact_goal config ~goal_id:goal.id (fun goal ->
       Ok ({ goal with phase = Goal_phase.Completed }, ()))
   with
   | Ok _ -> ()
   | Error error -> fail (Goal_store.write_error_to_string error));
  let ledger_before = ledger_bytes config in
  ignore (request ());
  check string "a completed goal stays completed" "completed" (stored_phase config goal.id);
  check string "a completed goal gets no new proof request" ledger_before (ledger_bytes config)
;;

(* The fixture links [.masc] at a directory inside the tree it later removes, so
   the cleanup alone has to finish that link; a dangling one must not be skipped
   either (#26648). *)
let test_rm_rf_unlinks_symlinks () =
  let dir = temp_dir () in
  let root = Filename.concat dir "base" in
  Unix.mkdir root 0o755;
  let first = Filename.concat root "first" in
  Unix.mkdir first 0o755;
  Unix.symlink first (Filename.concat root ".masc");
  Unix.symlink (Filename.concat root "gone") (Filename.concat root "dangling");
  rm_rf root;
  check bool "the tree is gone" false (Sys.file_exists root);
  rm_rf dir
;;

let busy_worker_polls = 50
let busy_worker_poll_interval_s = 0.01

(* Runs [action] while the one worker of a domain pool set for the occasion is
   held busy. Says whether [action] came back before the worker was released,
   and what it returned. *)
let beside_a_busy_worker env action =
  Eio.Switch.run
  @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  let previous_pool = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous_pool with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous)
  @@ fun () ->
  Domain_pool_ref.set pool;
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  let returned = ref None in
  let came_back_before_release = ref false in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.both
    (fun () -> returned := Some (action ()))
    (fun () ->
      let rec wait polls =
        if polls > 0 && Option.is_none !returned
        then (
          Eio.Time.sleep clock busy_worker_poll_interval_s;
          wait (polls - 1))
      in
      wait busy_worker_polls;
      came_back_before_release := Option.is_some !returned;
      Eio.Promise.resolve release_u ());
  match !returned with
  | Some value -> !came_back_before_release, value
  | None -> fail "the action never finished"
;;

(* A criterion whose title makes the ledger larger than the size from which a
   read decodes on the pool. *)
let large_criterion =
  Goal_store.Criterion
    { revision = "test-criterion"
    ; title = String.make (2 * Safe_ops.json_parse_offload_min_bytes) 't'
    ; metric = None
    ; target_value = None
    }
;;

let pending_ok config ~goal_id ~criterion =
  match Goal_verification.mark_proof_pending config ~goal_id ~criterion with
  | Ok _ -> ()
  | Error msg -> fail msg
;;

let records_ok config =
  match Goal_verification.load_records_by_goal_id_authoritative config with
  | Ok records -> records
  | Error msg -> fail msg
;;

(* Another process changes the ledger's bytes without changing what they
   decode to. *)
let change_ledger_bytes_outside_the_store config =
  let path = Goal_verification.verifications_path config in
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_binary ] 0o600 path
    (fun channel -> output_string channel "\n")
;;

(* A write encodes the ledger on the pool: while the pool's one worker is busy
   the write waits for it. The read the write starts with finds the ledger the
   earlier write kept, so the encode is the only job it submits. *)
let test_a_ledger_write_encodes_on_the_pool () =
  with_workspace_env
  @@ fun env config ->
  pending_ok config ~goal_id:"goal-seed" ~criterion:large_criterion;
  let came_back_before_release, () =
    beside_a_busy_worker env (fun () ->
      pending_ok config ~goal_id:"goal-next" ~criterion:isolated_criterion)
  in
  check bool "the write waits for the busy worker" false came_back_before_release;
  check int "and both records are stored" 2
    (Goal_store.Goal_id_map.cardinal (records_ok config))
;;

(* The store keeps what it wrote: a read after its own write of a large ledger
   decodes nothing, and comes back while the pool's one worker is busy. *)
let test_a_read_after_the_stores_own_write_decodes_nothing () =
  with_workspace_env
  @@ fun env config ->
  pending_ok config ~goal_id:"goal-large" ~criterion:large_criterion;
  let came_back_before_release, records =
    beside_a_busy_worker env (fun () -> records_ok config)
  in
  check bool "the read does not wait for the busy worker" true came_back_before_release;
  check int "and it holds the record" 1 (Goal_store.Goal_id_map.cardinal records)
;;

(* A large ledger whose bytes the store has not seen is decoded on the pool:
   the read waits for the busy worker. *)
let test_a_large_ledger_read_that_misses_decodes_on_the_pool () =
  with_workspace_env
  @@ fun env config ->
  pending_ok config ~goal_id:"goal-large" ~criterion:large_criterion;
  change_ledger_bytes_outside_the_store config;
  let came_back_before_release, records =
    beside_a_busy_worker env (fun () -> records_ok config)
  in
  check bool "the read waits for the busy worker" false came_back_before_release;
  check int "and it holds the record" 1 (Goal_store.Goal_id_map.cardinal records)
;;

(* What the store keeps after a write is what a reader decodes from the file.
   The criterion title is not valid UTF-8, so the bytes written carry a
   repaired string where the state the mutation built carries the original. *)
let test_the_state_kept_after_a_write_is_the_state_the_file_decodes_to () =
  with_workspace
  @@ fun config ->
  let criterion =
    Goal_store.Criterion
      { revision = "test-criterion"; title = "caf\xff"; metric = None; target_value = None }
  in
  pending_ok config ~goal_id:"goal-repaired" ~criterion;
  let kept = records_ok config in
  change_ledger_bytes_outside_the_store config;
  let decoded = records_ok config in
  check bool "the second read decoded the file" false (kept == decoded);
  check bool "and decoded the records that were kept" true
    (Goal_store.Goal_id_map.equal ( = ) kept decoded);
  match Goal_store.Goal_id_map.find_opt "goal-repaired" kept with
  | Some { completion = Proof_pending { criterion = Criterion { title; _ }; _ }; _ } ->
    check bool "whose title is the repaired one" false (String.equal title "caf\xff")
  | Some _ | None -> fail "the kept record is not the pending request"
;;

let () =
  if Array.length Sys.argv = 2 && String.equal Sys.argv.(1) proof_mirror_presence_flag then
    proof_mirror_presence_scenario ()
  else if Array.length Sys.argv = 2 && String.equal Sys.argv.(1) proof_primary_fifo_flag then
    proof_primary_fifo_scenario ()
  else run
    "goal_verification_gate"
    [ ( "temp directory cleanup"
      , [ test_case "rm_rf unlinks live and dangling links" `Quick
            test_rm_rf_unlinks_symlinks ] )
    ; ( "ledger encoding and decoding"
      , [ test_case "a ledger write encodes on the pool" `Quick
            test_a_ledger_write_encodes_on_the_pool
        ; test_case "a read after the store's own write decodes nothing" `Quick
            test_a_read_after_the_stores_own_write_decodes_nothing
        ; test_case "a large ledger read that misses decodes on the pool" `Quick
            test_a_large_ledger_read_that_misses_decodes_on_the_pool
        ; test_case "the state kept after a write is the state the file decodes to" `Quick
            test_the_state_kept_after_a_write_is_the_state_the_file_decodes_to
        ] )
    ; ( "durable proof effects"
      , [ test_case "proof request follows the phase machine" `Quick
            test_proof_request_follows_the_phase_machine
        ; test_case "audit and partial recipient failures recover exactly once" `Quick
            test_proof_effect_delivery_recovers_audit_and_partial_recipients
        ; test_case "mention recovery proceeds while original Goal delivery is locked" `Quick
            test_maintenance_mention_delivery_proceeds_while_goal_delivery_is_locked
        ; test_case "scan and explicit repeat retain effects across rename/delete" `Quick
            test_proof_delivery_survives_reconciliation_and_goal_removal
        ; test_case "roster read failure cannot become an empty audience" `Quick
            test_roster_read_failure_keeps_the_goal_notification_uncaptured ])
    ; ( "b1 creation requirement"
      , [ test_case "creation requires a success condition" `Quick
            test_create_requires_a_success_condition
        ; test_case "creation with a success condition succeeds" `Quick
            test_create_with_a_success_condition_succeeds
        ; test_case "blank public edits preserve pending proof and audit" `Quick
            test_blank_public_criterion_edits_preserve_pending_proof
        ; test_case "partial update preserves stored success condition" `Quick
            test_partial_update_preserves_success_condition
        ; test_case "undecodable goal store reports corruption, not B1" `Quick
            test_undecodable_goal_store_reports_corruption_not_b1
        ] )
    ; ( "ledger record-only discipline"
      , [ test_case "proof verdict requires a pending request" `Quick
            test_proof_verdict_requires_a_pending_request
        ; test_case "stale proof cannot consume a revised criterion" `Quick
            test_stale_proof_request_cannot_consume_revised_criterion
        ; test_case "criterion edit records its phase move" `Quick
            test_criterion_edit_records_its_phase_move
        ; test_case "criterion edit on an executing goal records no phase move" `Quick
            test_criterion_edit_on_executing_goal_records_no_phase_move
        ; test_case "proof replay retains evidence and rejects another run" `Quick
            test_proof_replay_preserves_evidence_and_rejects_different_run
        ; test_case "recovered Goal cannot authorize edits or deletion" `Quick
            test_recovered_goal_cannot_authorize_edits_or_deletion
        ; test_case "recovery proof cannot authorize mutation" `Quick
            test_recovery_proof_cannot_authorize_mutation
        ; test_case "unknown proof mirror refuses admission without reading it" `Quick
            test_proof_mirror_presence_guarded
        ; test_case "FIFO primary is an unreadable ledger, not a blocked read" `Quick
            test_proof_primary_fifo_guarded
        ; test_case "Memory cannot authorize a durable Goal proof" `Quick
            test_memory_proof_cannot_supply_authority
        ] )
    ; ( "store discipline"
      , [ test_case "undecodable ledger fails closed and loud" `Quick
            test_undecodable_ledger_fails_closed_and_loud
        ; test_case "unknown ledger field is a decode error" `Quick
            test_unknown_ledger_field_is_a_decode_error
        ; test_case "human confirmation requires a bound verdict" `Quick
            test_human_confirmation_requires_bound_verdict
        ] )
    ; ( "observability"
      , [ test_case "goal list joins the ledger" `Quick
            test_goal_list_joins_the_ledger
        ; test_case "goal list renders a ledger-error state" `Quick
            test_goal_list_renders_a_ledger_error_state
        ; test_case "measurements require current criterion and evidence" `Quick
            test_measurement_requires_current_criterion_and_evidence
        ; test_case "measurement receipt preserves lifecycle and criterion" `Quick
            test_measurement_receipt_preserves_lifecycle_and_criterion
        ; test_case "measurement evidence is an Evidence Reference" `Quick
            test_measurement_evidence_is_an_evidence_reference
        ; test_case "measurement rows follow Goal existence, not phase" `Quick
            test_measurement_rows_follow_goal_existence_not_phase
        ; test_case "stored non-reference evidence is unreadable" `Quick
            test_stored_non_reference_evidence_is_unreadable
        ] )
    ; ( "stage 2 gate"
      , [ test_case "reopen works before any completion request" `Quick
            test_reopen_without_any_verification_history
        ; test_case "reopen starts a new verification cycle and preserves history" `Quick
            test_reopened_goal_enters_a_new_verification_cycle
        ; test_case "dropped pending proof gets a new request after reopen" `Quick
            test_dropped_pending_proof_gets_a_new_request_after_reopen
        ; test_case "goal failures take the class of their code" `Quick
            test_goal_failures_take_the_class_of_their_code
        ; test_case "verdict after drop from verifying is refused" `Quick
            test_verdict_after_drop_from_verifying_is_refused
        ; test_case "reopen from verifying clears the pending request" `Quick
            test_reopen_from_verifying_clears_the_pending_request
        ; test_case "repeated reopen preserves a newer refuted proof" `Quick
            test_repeated_reopen_preserves_a_new_refuted_proof
        ; test_case "failed reopen archive can be retried without losing proof" `Quick
            test_reopen_archive_failure_is_recoverable_without_losing_proof
        ; test_case "unreadable goal cannot reset a proof" `Quick
            test_reopen_reset_refuses_an_unreadable_goal_source
        ; test_case "recovered ledger cannot authorize proof reset" `Quick
            test_reopen_reset_refuses_a_recovered_verification_ledger
        ; test_case "request_complete enters verifying with proof pending" `Quick
            test_request_complete_enters_verifying_with_proof_pending
        ; test_case "proof proven completes with authority and evidence" `Quick
            test_proof_proven_completes_with_authority_and_evidence
        ; test_case "proof refuted returns to executing with reason" `Quick
            test_proof_refuted_returns_to_executing_with_reason
        ; test_case "uncertain verifying proof cannot create a new request" `Quick
            test_verifying_does_not_recreate_an_unknown_request
        ; test_case "active verification retains its submitted evidence" `Quick
            test_verifying_retry_preserves_its_evidence_snapshot
        ; test_case "retry is bound to the observed proof request" `Quick
            test_bound_retry_does_not_create_or_replace_a_request
        ; test_case "unbound verifying retry rechecks a changed Goal" `Quick
            test_verifying_repeat_refuses_changed_goal
        ; test_case "initial request refuses a new verifying Goal" `Quick
            test_initial_request_refuses_a_new_verifying_goal
        ; test_case "terminal verifying retry does not discard evidence" `Quick
            test_verifying_repeat_preserves_terminal_evidence_contract
        ; test_case "recovery preserves a verdict committed after the scan" `Quick
            test_recovery_reconciles_a_verdict_committed_after_the_scan
        ; Alcotest.test_case "workspace binding refuses another workspace" `Quick
            test_transition_refuses_a_different_workspace
        ; Alcotest.test_case "Goal cache follows the resolved store root" `Quick
            test_goal_cache_scope_tracks_the_resolved_store
        ; test_case "verifying repeat wakes an existing proof request" `Quick
            test_verifying_repeat_wakes_an_existing_proof_request
        ; test_case "verifying repeat reconciles a committed proof" `Quick
            test_verifying_repeat_reconciles_a_committed_proof
        ; test_case "keeper keeps and sees a verifying goal" `Quick
            test_keeper_keeps_and_sees_a_verifying_goal
        ; test_case "corrupt ledger fails request_complete loudly" `Quick
            test_corrupt_ledger_fails_request_complete_loudly
        ] )
    ; ( "before proof commit"
      , [ test_case "the step sees the passing verdict before it is written" `Quick
            test_step_sees_the_passing_verdict_before_it_is_written
        ; test_case "a refusing step leaves the proof pending" `Quick
            test_a_refusing_step_leaves_the_proof_pending
        ; test_case "the step does not run for a refutation" `Quick
            test_the_step_does_not_run_for_a_refutation
        ; test_case "the step does not run again for a replayed verdict" `Quick
            test_the_step_does_not_run_again_for_a_replayed_verdict
        ] )
    ]
;;
