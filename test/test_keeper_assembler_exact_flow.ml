open Alcotest
open Masc

module Descriptor = Keeper_tool_descriptor
module Exact = Exact_lane_run_registry
module Fixture = Compaction_exact_output_fixture
module Flow = Keeper_assembler_exact_flow
module Proposal = Keeper_plan_proposal
module Request = Keeper_assembler_request
module Store = Keeper_plan_proposal_store
module Surface = Keeper_capability_surface

exception Cancel_after_request_arrived

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stat when stat.Unix.st_kind = Unix.S_DIR ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let with_temp_base f =
  let base_path = Filename.temp_dir "keeper-assembler-exact-flow" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let prompt_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

let with_prompt_registry f =
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
       Prompt_registry.clear ();
       Prompt_registry.set_markdown_dir (prompt_root ());
       Prompt_defaults.init ();
       f ())
;;

let empty_skill_snapshot =
  Skill_catalog_snapshot.config_unreadable ~detail:"fixture has no Skill sources"
;;

let surface () =
  let empty_skills =
    Keeper_skill_catalog.of_snapshot empty_skill_snapshot |> fst
  in
  Surface.create
    ~tool_groups:None
    ~skill_names:None
    ~global_skill_catalog:empty_skills
    ~skill_inventory:(Keeper_skill_inventory.of_snapshot empty_skill_snapshot)
    ~task_skills:[]
;;

let reference surface name =
  Surface.tool_capabilities surface
  |> List.find_opt (fun (capability : Surface.tool_capability) ->
    Descriptor.keeper_model_names capability.descriptor
    |> List.exists (String.equal name))
  |> function
  | Some capability -> Surface.ordinary_tool_reference capability
  | None -> failf "missing active Tool %S" name
;;

let request surface =
  let reference = reference surface "keeper_time_now" in
  Request.of_yojson
    ~capability_surface:surface
    (`Assoc
      [ "objective", `String "Read the current time"
      ; "execution", `String "inline"
      ; ( "ordinary_tool_references"
        , `List [ Surface.ordinary_tool_reference_to_yojson reference ] )
      ])
  |> function
  | Ok request -> request
  | Error error ->
    failf "request fixture rejected: %s" (Request.error_to_yojson error |> Yojson.Safe.to_string)
;;

let plan_output =
  `Assoc
    [ "kind", `String "plan"
    ; ( "plan"
      , `Assoc
          [ ( "nodes"
            , `List
                [ `Assoc
                    [ "id", `String "clock"
                    ; "tool", `String "keeper_time_now"
                    ]
                ] )
          ] )
    ]
;;

let cannot_assemble_output = `Assoc [ "kind", `String "cannot_assemble" ]

let invalid_plan_output =
  `Assoc
    [ "kind", `String "plan"
    ; "plan", `Assoc [ "nodes", `List [] ]
    ]
;;

let publish_lane fixtures =
  let snapshot =
    Fixture.resolver_snapshot
      ~supports_response_format_json:true
      ~supports_structured_output:false
      ~source:"Assembler exact-flow conformance"
      fixtures
  in
  match
    Fixture.publish_registry
      ~lane_id:Flow.lane_id
      ~slot_ids:
        (List.map (fun (fixture : Fixture.target_fixture) -> fixture.id) fixtures)
      snapshot
  with
  | _registry -> ()
;;

let object_has_field field = function
  | `Assoc fields -> List.mem_assoc field fields
  | _ -> false
;;

let assert_no_provider_tool_surface server =
  Fixture.request_bodies server
  |> List.iter (fun body ->
    let json = Yojson.Safe.from_string body in
    check bool "request has no tools field" false (object_has_field "tools" json);
    check bool "request has no tool_choice field" false
      (object_has_field "tool_choice" json))
;;

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let with_eio_base _prefix f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env
    ~net
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  with_temp_base @@ fun base_path ->
  with_prompt_registry @@ fun () ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config_uncached base_path in
  Fs_compat.mkdir_p (Workspace.masc_root_dir config);
  let request = request (surface ()) in
  f ~sw ~net ~clock ~base_path ~config ~request
;;

let test_semantic_rejection_advances_and_only_stores_the_proposal () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.with_test_env
    ~net
    ~clock
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
  @@ fun () ->
  with_temp_base @@ fun base_path ->
  with_prompt_registry @@ fun () ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Workspace.default_config_uncached base_path in
  Fs_compat.mkdir_p (Workspace.masc_root_dir config);
  let invalid =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response invalid_plan_output))
  in
  let declined =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response cannot_assemble_output))
  in
  let accepted =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response plan_output))
  in
  publish_lane
    [ { Fixture.id = "assembler-invalid"; base_url = invalid.base_url }
    ; { Fixture.id = "assembler-declined"; base_url = declined.base_url }
    ; { Fixture.id = "assembler-accepted"; base_url = accepted.base_url }
    ];
  let request = request (surface ()) in
  let prepared =
    Flow.prepare ~config ~keeper_name:"assembler-test" request
    |> function
    | Ok prepared -> prepared
    | Error error ->
      failf "prepare failed: %s" (Flow.setup_error_to_yojson error |> Yojson.Safe.to_string)
  in
  let observations =
    Exact.create ~path:(Filename.concat base_path "assembler-runs.jsonl") ()
  in
  let result =
    Flow.execute ~net ~clock ~observation_registry:observations prepared
    |> function
    | Ok success -> success
    | Error error ->
      failf "execute failed: %s" (Flow.execution_error_to_yojson error |> Yojson.Safe.to_string)
  in
  check int "invalid plan candidate called once" 1 (Fixture.post_count invalid);
  check int "cannot_assemble candidate called once" 1 (Fixture.post_count declined);
  check int "accepted candidate called once" 1 (Fixture.post_count accepted);
  check string "success records the accepting slot" "assembler-accepted"
    result.selected_slot;
  (match result.store_result with
   | Store.Stored -> ()
   | Store.Already_present -> fail "fresh proposal was unexpectedly deduplicated");
  assert_no_provider_tool_surface invalid;
  assert_no_provider_tool_surface declined;
  assert_no_provider_tool_surface accepted;
  let loaded =
    Store.load
      ~descriptors:(Request.descriptors request)
      config
      (Proposal.id result.proposal)
    |> function
    | Ok proposal -> proposal
    | Error error ->
      failf "stored proposal did not load: %s" (Store.error_to_yojson error |> Yojson.Safe.to_string)
  in
  check string "stored proposal id"
    (Proposal.id result.proposal |> Proposal.Proposal_id.to_string)
    (Proposal.id loaded |> Proposal.Proposal_id.to_string);
  check bool "ordinary Tool dispatch log remains absent" false
    (Sys.file_exists
       (Filename.concat (Workspace.masc_root_dir config) "tool_calls"));
  match Exact.list_runs observations with
  | [ run ] ->
    check string "one Assembler run" Flow.lane_id (Exact.lane_key run.lane);
    (match run.status with
     | Exact.Completed
         { outcome = Exact.Succeeded; selected_slot = Some selected_slot; output; _ } ->
       check string "observed selected slot" "assembler-accepted" selected_slot;
       check
         (option string)
         "proposal identity stays in lane-specific output"
         (Some (Proposal.id result.proposal |> Proposal.Proposal_id.to_string))
         (match field "proposal_id" output with
          | Some (`String value) -> Some value
          | _ -> None);
       check bool "generic subject remains explicit absence" true
         (field "subject_id" (Exact.run_summary_to_yojson run) = Some `Null);
       (match field "semantic_rejections" output with
        | Some (`List [ invalid; declined ]) ->
          check (option string) "invalid plan rejection is retained"
            (Some "output_invalid")
            (match field "kind" invalid with
             | Some (`String kind) -> Some kind
             | _ -> None);
          check (option string) "cannot_assemble rejection is retained"
            (Some "cannot_assemble")
            (match field "kind" declined with
             | Some (`String kind) -> Some kind
             | _ -> None)
        | Some (`List rejections) ->
          failf "expected two semantic rejections, got %d" (List.length rejections)
        | _ -> fail "semantic rejections were not observed")
     | _ -> fail "Assembler run did not complete successfully")
  | runs -> failf "expected one observed Assembler run, got %d" (List.length runs)
;;

let test_missing_or_empty_prompt_fails_before_flow_allocation () =
  with_temp_base @@ fun empty_prompt_root ->
  Fun.protect
    ~finally:Prompt_registry.clear
    (fun () ->
       Prompt_registry.clear ();
       Prompt_registry.set_markdown_dir empty_prompt_root;
       let request = request (surface ()) in
       match
         Flow.prepare
           ~config:(Workspace.default_config_uncached empty_prompt_root)
           ~keeper_name:"assembler-missing-prompt"
           request
       with
       | Error (Flow.Prompt_render_failed _) -> ()
       | Error error ->
         failf
           "wrong missing prompt error: %s"
           (Flow.setup_error_to_yojson error |> Yojson.Safe.to_string)
       | Ok _ -> fail "missing Assembler prompt allocated a flow")
;;

let test_execution_failure_json_keeps_typed_provider_evidence () =
  let json =
    Flow.exact_execution_failure_to_yojson
      (Flow.Candidate_execution_failed
         { slot_id = "assembler-primary"
         ; call_id = "call-1"
         ; cause =
             Agent_core.Exact_output.Provider_response_refused
               { http_status = 429; refusal = Agent_core.Exact_output.Rate_limited }
         ; raw_response_sha256 = Some (String.make 64 'a')
         ; evidence = "slot=assembler-primary call_id=call-1"
         })
  in
  let cause = field "cause" json |> Option.value ~default:`Null in
  check (option string) "failure kind" (Some "candidate_execution_failed")
    (match field "kind" json with Some (`String value) -> Some value | _ -> None);
  check (option int) "HTTP status" (Some 429)
    (match field "http_status" cause with Some (`Int value) -> Some value | _ -> None);
  check (option string) "typed refusal" (Some "rate_limited")
    (match field "refusal" cause with Some (`String value) -> Some value | _ -> None);
  check (option string) "attempt identity" (Some "call-1")
    (match field "call_id" json with Some (`String value) -> Some value | _ -> None)
;;

let test_provider_failure_records_typed_failed_observation () =
  with_eio_base "assembler-provider-failure"
  @@ fun ~sw ~net ~clock ~base_path ~config ~request ->
  let failed =
    Fixture.start_server ~sw ~net ~clock Fixture.Abort_after_request
  in
  publish_lane
    [ { Fixture.id = "assembler-provider-failed"; base_url = failed.base_url } ];
  let prepared =
    Flow.prepare ~config ~keeper_name:"assembler-provider-failure" request
    |> function
    | Ok prepared -> prepared
    | Error error ->
      failf "prepare failed: %s" (Flow.setup_error_to_yojson error |> Yojson.Safe.to_string)
  in
  let observations =
    Exact.create ~path:(Filename.concat base_path "provider-failure-runs.jsonl") ()
  in
  let failed_slot_id, failed_call_id, failure_json =
    match Flow.execute ~net ~clock ~observation_registry:observations prepared with
    | Error
        (Flow.Exact_execution_failed
          { failure = Flow.Candidate_execution_failed failure
          ; prior_semantic_rejections = []
          }) ->
      ( failure.slot_id
      , failure.call_id
      , Flow.exact_execution_failure_to_yojson
          (Flow.Candidate_execution_failed failure) )
    | Error error ->
      failf
        "wrong provider failure: %s"
        (Flow.execution_error_to_yojson error |> Yojson.Safe.to_string)
    | Ok _ -> fail "aborted provider request unexpectedly succeeded"
  in
  check int "provider POST count" 1 (Fixture.post_count failed);
  check string "failed slot identity" "assembler-provider-failed" failed_slot_id;
  check bool "attempt call identity retained" true
    (String.trim failed_call_id <> "");
  (match Exact.list_runs observations with
   | [ run ] ->
     (match run.status with
      | Exact.Completed
          { outcome = Exact.Failed { code; _ }
          ; selected_slot = Some selected_slot
          ; output
          ; _
          } ->
        check string "failed outcome code" "exact_execution_failed" code;
        check string "observed failed slot" failed_slot_id selected_slot;
        check bool "typed failure output preserved" true
          (field "failure" output = Some failure_json)
      | _ -> fail "provider failure did not produce a Failed observation")
   | runs -> failf "expected one failed observation, got %d" (List.length runs))
;;

let test_provider_cancellation_records_cancelled_and_reraises_origin () =
  with_eio_base "assembler-provider-cancellation"
  @@ fun ~sw ~net ~clock ~base_path ~config ~request ->
  let delayed =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Delay_then_reply
         (60.0, Fixture.openai_response plan_output))
  in
  publish_lane
    [ { Fixture.id = "assembler-cancelled"; base_url = delayed.base_url } ];
  let prepared =
    Flow.prepare ~config ~keeper_name:"assembler-cancellation" request
    |> function
    | Ok prepared -> prepared
    | Error error ->
      failf "prepare failed: %s" (Flow.setup_error_to_yojson error |> Yojson.Safe.to_string)
  in
  let observations =
    Exact.create ~path:(Filename.concat base_path "cancelled-runs.jsonl") ()
  in
  let cancel_context, resolve_cancel_context = Eio.Promise.create () in
  let execution =
    Eio.Fiber.fork_promise ~sw (fun () ->
      Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve resolve_cancel_context context;
        Flow.execute ~net ~clock ~observation_registry:observations prepared))
  in
  let outcome =
    match
      Eio.Time.with_timeout_exn clock 1.0 (fun () ->
        let context = Eio.Promise.await cancel_context in
        Fixture.await_first_request delayed;
        Eio.Cancel.cancel context Cancel_after_request_arrived;
        Eio.Promise.await_exn execution)
    with
    | value -> `Returned value
    | exception Eio.Time.Timeout -> fail "cancellation watchdog expired"
    | exception exn -> `Raised exn
  in
  (match outcome with
   | `Raised (Eio.Cancel.Cancelled Cancel_after_request_arrived) -> ()
   | `Raised exn ->
     failf "cancellation raised the wrong exception: %s" (Printexc.to_string exn)
   | `Returned (Error error) ->
     failf
       "cancellation became a returned terminal: %s"
       (Flow.execution_error_to_yojson error |> Yojson.Safe.to_string)
   | `Returned (Ok _) -> fail "cancelled flow unexpectedly succeeded");
  check int "cancelled provider POST count" 1 (Fixture.post_count delayed);
  match Exact.list_runs observations with
  | [ run ] ->
    (match run.status with
     | Exact.Completed
         { outcome = Exact.Cancelled
         ; selected_slot = Some "assembler-cancelled"
         ; output = `Null
         ; _
         } -> ()
     | _ -> fail "cancelled provider flow did not persist Cancelled observation")
  | runs -> failf "expected one cancelled observation, got %d" (List.length runs)
;;

let test_keeper_preference_dispatches_only_the_preferred_candidate () =
  with_eio_base "assembler-keeper-preference"
  @@ fun ~sw ~net ~clock ~base_path ~config ~request ->
  let response = Fixture.openai_response plan_output in
  let lane_default =
    Fixture.start_server ~sw ~net ~clock (Fixture.Reply response)
  in
  let preferred =
    Fixture.start_server ~sw ~net ~clock (Fixture.Reply response)
  in
  publish_lane
    [ { Fixture.id = "assembler-default"; base_url = lane_default.base_url }
    ; { Fixture.id = "assembler-preferred"; base_url = preferred.base_url }
    ];
  (match
     Keeper_exact_lane_preference.set
       config
       ~actor:"test"
       ~keeper_name:"assembler-preference"
       ~lane_id:Flow.lane_id
       (Some "assembler-preferred")
   with
   | Ok (Some row) ->
     check string "stored preference" "assembler-preferred" row.slot_id
   | Ok None -> fail "preference write returned no row"
   | Error detail -> fail detail);
  let prepared =
    Flow.prepare ~config ~keeper_name:"assembler-preference" request
    |> function
    | Ok prepared -> prepared
    | Error error ->
      failf "prepare failed: %s" (Flow.setup_error_to_yojson error |> Yojson.Safe.to_string)
  in
  let observations =
    Exact.create ~path:(Filename.concat base_path "preference-runs.jsonl") ()
  in
  let success =
    Flow.execute ~net ~clock ~observation_registry:observations prepared
    |> function
    | Ok success -> success
    | Error error ->
      failf "preferred flow failed: %s"
        (Flow.execution_error_to_yojson error |> Yojson.Safe.to_string)
  in
  check int "lane default was not dispatched" 0 (Fixture.post_count lane_default);
  check int "preferred candidate dispatched exactly once" 1
    (Fixture.post_count preferred);
  check string "preferred success slot" "assembler-preferred" success.selected_slot;
  match Exact.list_runs observations with
  | [ { Exact.status = Exact.Completed { selected_slot = Some selected_slot; _ }; _ } ] ->
    check string "preferred observed slot" "assembler-preferred" selected_slot
  | _ -> fail "preferred execution observation is missing"
;;

let () =
  ignore (Masc_test_deps.init_unified_tool_registry ());
  run
    "keeper assembler exact flow"
    [ ( "producer"
      , [ test_case
            "semantic rejection advances and stores without Tool dispatch"
            `Quick
            test_semantic_rejection_advances_and_only_stores_the_proposal
        ; test_case
            "missing prompt fails before flow allocation"
            `Quick
            test_missing_or_empty_prompt_fails_before_flow_allocation
        ; test_case
            "execution failure keeps typed provider evidence"
            `Quick
            test_execution_failure_json_keeps_typed_provider_evidence
        ; test_case
            "provider failure records typed failed observation"
            `Quick
            test_provider_failure_records_typed_failed_observation
        ; test_case
            "provider cancellation records cancelled and reraises origin"
            `Quick
            test_provider_cancellation_records_cancelled_and_reraises_origin
        ; test_case
            "keeper preference dispatches only the preferred candidate"
            `Quick
            test_keeper_preference_dispatches_only_the_preferred_candidate
        ] )
    ]
;;
