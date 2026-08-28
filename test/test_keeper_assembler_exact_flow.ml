open Alcotest
open Masc

module Descriptor = Keeper_tool_descriptor
module Async = Keeper_msg_async
module Catalog = Keeper_tool_composition_catalog
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

let ordered_duplicate_plan_output =
  `Assoc
    [ "kind", `String "plan"
    ; ( "plan"
      , `Assoc
          [ ( "nodes"
            , `List
                [ `Assoc
                    [ "id", `String "clock-before"
                    ; "tool", `String "keeper_time_now"
                    ]
                ; `Assoc
                    [ "id", `String "context"
                    ; "tool", `String "keeper_context_status"
                    ]
                ; `Assoc
                    [ "id", `String "clock-after"
                    ; "tool", `String "keeper_time_now"
                    ]
                ] )
          ] )
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

let assembler_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "trace_id", `String (name ^ "-trace")
        ; "allowed_paths", `List [ `String "*" ]
        ])
  with
  | Ok meta -> meta
  | Error detail -> fail detail
;;

let find_agent_core_tool tools name =
  List.find_opt
    (fun (tool : Agent_core.Tool.t) ->
       String.equal tool.schema.Agent_core.Types.name name)
    tools
  |> function
  | Some tool -> tool
  | None -> failf "Agent-Core bundle omitted %s" name
;;

let await_async_done ~clock ~config ~caller request_id =
  (* The worker is a single local read Tool in this scenario. Five seconds is
     a test-runner deadlock guard, not product scheduling policy; measured
     completion is below one millisecond after the broker accepts it. *)
  Eio.Time.with_timeout_exn clock 5.0 (fun () ->
    let rec loop () =
      match Async.poll ~base_path:config.Workspace.base_path ~caller request_id with
      | Async.Found
          { status = Async.Done { ok = true; data = Some data; _ }; _ } ->
        data
      | Async.Found
          { status = Async.Done { ok = true; data = None; _ }; _ } ->
        fail "async proposal completed without typed data"
      | Async.Found
          { status = Async.Done { ok = false; body; _ }; _ } ->
        failf "async proposal failed: %s" body
      | Async.Found
          { status = (Async.Queued | Async.Running | Async.Cancelling _); _ } ->
        Eio.Fiber.yield ();
        loop ()
      | Async.Found { status = Async.Lost { reason }; _ }
      | Async.Found { status = Async.Cancelled { reason; _ }; _ }
      | Async.Found { status = Async.Persistence_failed { reason; _ }; _ }
      | Async.Unreadable reason ->
        failf "async proposal lost durable truth: %s" reason
      | Async.Absent -> fail "async proposal request disappeared"
      | Async.Rejected _ -> fail "async proposal request ownership was rejected"
    in
    loop ())
;;

let test_model_visible_tool_produces_proposal_without_tool_execution () =
  with_eio_base "assembler-model-visible-tool"
  @@ fun ~sw ~net ~clock ~base_path:_ ~config ~request:_ ->
  let accepted =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response ordered_duplicate_plan_output))
  in
  publish_lane
    [ { Fixture.id = "assembler-tool-accepted"; base_url = accepted.base_url } ];
  let capability_surface = surface () in
  let time_reference = reference capability_surface "keeper_time_now" in
  let context_reference = reference capability_surface "keeper_context_status" in
  let board_reference = reference capability_surface "masc_board_list" in
  let meta = assembler_meta "assembler-tool-test" in
  let publication_recovery =
    { Keeper_publication_recovery_availability.provider =
        Keeper_publication_recovery_availability.non_runtime_provider
    ; keeper_name = meta.name
    }
  in
  let turn_ctx_cell = Keeper_tool_call_log.create_turn_ctx_cell () in
  Keeper_tool_call_log.set_turn_context
    ~cell:turn_ctx_cell
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
    ~session_id:"assembler-tool-session"
    ~turn:1
    ();
  let bundle =
    Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot:
        (Keeper_context_runtime.create
           ~eio:false
           ~system_prompt:"assembler Tool test")
      ~clock
      ~turn_ctx_cell
      ~capability_surface
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      bundle.cleanup ();
      Keeper_tool_call_log.reset_for_testing ())
    (fun () ->
       let tool = find_agent_core_tool bundle.tools "keeper_assemble_plan" in
       let input =
         `Assoc
           [ "objective", `String "Read the current time"
           ; "execution", `String "inline"
           ; ( "ordinary_tool_references"
             , `List
                 [ Surface.ordinary_tool_reference_to_yojson time_reference
                 ; Surface.ordinary_tool_reference_to_yojson context_reference
                 ] )
           ]
       in
       let output =
         match Agent_core.Tool.execute tool input with
         | Ok output -> Yojson.Safe.from_string output.content
         | Error error -> failf "keeper_assemble_plan failed: %s" error.message
       in
       check bool "Tool result succeeded" true
         (field "ok" output = Some (`Bool true));
       check int "Assembler provider called exactly once" 1
         (Fixture.post_count accepted);
       assert_no_provider_tool_surface accepted;
       let proposal_id =
         match field "proposal_id" output with
         | Some (`String value) -> value
         | _ -> fail "Tool result omitted proposal_id"
       in
       let execution_request =
         match field "execution_request" output with
         | Some (`Assoc fields as request) ->
          check (option string) "execution request binds the Assembler run"
            (match field "run_id" output with
             | Some (`String value) -> Some value
             | _ -> None)
            (match List.assoc_opt "assembler_run_id" fields with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "execution request binds the proposal id"
            (Some proposal_id)
            (match List.assoc_opt "proposal_id" fields with
             | Some (`String value) -> Some value
             | _ -> None);
          check (list string) "execution request preserves Tool order and duplicates"
            [ "keeper_time_now"; "keeper_context_status"; "keeper_time_now" ]
            (match List.assoc_opt "approval_tools" fields with
             | Some (`List values) ->
               List.map
                 (function
                   | `String value -> value
                   | _ -> fail "execution request contains a non-string Tool")
                 values
             | _ -> fail "execution request omitted approval_tools");
           request
         | _ -> fail "Tool result omitted the exact execution request"
       in
       let proposal_id =
         match Proposal.Proposal_id.of_string proposal_id with
         | Ok proposal_id -> proposal_id
         | Error Proposal.Proposal_id.Not_lowercase_sha256 ->
           fail "Tool result proposal_id is not content-addressed"
       in
       let proposal =
         match
           Store.load
             ~descriptors:(Surface.descriptors capability_surface)
             config
             proposal_id
         with
         | Ok proposal -> proposal
         | Error error ->
           failf "Tool result proposal did not load: %s"
             (Store.error_to_yojson error |> Yojson.Safe.to_string)
       in
       check string "Tool result digest matches stored proposal"
         (Proposal.digest proposal)
         (match field "proposal_digest" output with
          | Some (`String value) -> value
          | _ -> "");
       let run_id =
         match field "run_id" output with
         | Some (`String value) -> value
         | _ -> fail "Tool result omitted run_id"
       in
       (match Exact.get (Exact.global ()) ~run_id with
        | Some
            { status =
                Exact.Completed
                  { outcome = Exact.Succeeded
                  ; selected_slot = Some "assembler-tool-accepted"
                  ; _
                  }
            ; _
            } -> ()
        | Some _ -> fail "Tool run ledger did not record typed success"
        | None -> fail "Tool run ledger omitted returned run_id");
       check bool "ordinary Tool dispatch log remains absent" false
         (Sys.file_exists
            (Filename.concat (Workspace.masc_root_dir config) "tool_calls"));
       Keeper_tool_call_log.reset_for_testing ();
       Keeper_tool_call_log.init ~base_path:config.base_path ();
       let proposal_tool =
         find_agent_core_tool bundle.tools "keeper_proposal_execute"
       in
       let invocation tool_use_id =
         Agent_core.Tool_contract.Invocation.create
           ~tool_use_id
           ~turn:1
           ~schedule:
             { Agent_core.Tool_contract.planned_index = 0
             ; batch_index = 0
             ; batch_size = 1
             ; execution_mode = Agent_core.Tool_contract.Serial
             }
           ~completion:(Agent_core.Tool.completion proposal_tool)
       in
       let tampered_request =
         match execution_request with
         | `Assoc fields ->
           `Assoc
             (List.map
                (fun (name, value) ->
                   if String.equal name "approval_tools"
                   then name, `List [ `String "keeper_context_status" ]
                   else name, value)
                fields)
         | _ -> assert false
       in
       (match Agent_core.Tool.execute proposal_tool execution_request with
        | Ok _ -> fail "proposal executed without Agent-Core invocation identity"
        | Error error ->
          check string "missing invocation is rejected explicitly"
            "proposal execution requires Agent-Core invocation identity"
            error.message);
       let contradictory_run_id = "assembler-proposal-wrong-lane" in
       Exact.register_running
         (Exact.global ())
         ~run_id:contradictory_run_id
         ~lane:Exact.Librarian
         ~actor:meta.name
         ~started_at:1.0
         ~input:(Exact.Exact_input `Null);
       let contradictory_request =
         match execution_request with
         | `Assoc fields ->
           `Assoc
             (List.map
                (fun (name, value) ->
                   if String.equal name "assembler_run_id"
                   then name, `String contradictory_run_id
                   else name, value)
                fields)
         | _ -> assert false
       in
       (match
          Agent_core.Tool.execute
            ~invocation:(invocation "assembler-proposal-contradiction")
            proposal_tool
            contradictory_request
        with
        | Ok _ -> fail "contradictory producer provenance executed the proposal"
        | Error error ->
          let payload =
            Yojson.Safe.from_string error.message
            |> Yojson.Safe.Util.member "masc.payload"
          in
          check (option string) "producer contradiction is typed"
            (Some "proposal_provenance_contradiction")
            (match field "error" payload with
             | Some (`String value) -> Some value
             | _ -> None));
       check int "pre-effect refusals emitted no composition rows" 0
         (Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:8 ()
          |> List.length);
       (match
          Agent_core.Tool.execute
            ~invocation:(invocation "assembler-proposal-tampered")
            proposal_tool
            tampered_request
        with
        | Ok _ -> fail "tampered approval sequence executed the proposal"
        | Error error ->
          let payload =
            Yojson.Safe.from_string error.message
            |> Yojson.Safe.Util.member "masc.payload"
          in
          check (option string) "tampered sequence is typed"
            (Some "proposal_approval_tools_mismatch")
            (match field "error" payload with
             | Some (`String value) -> Some value
             | _ -> None));
       let execution_output =
         match
           Agent_core.Tool.execute
             ~invocation:(invocation "assembler-proposal-execute")
             proposal_tool
             execution_request
         with
         | Error error ->
           failf "keeper_proposal_execute failed: %s" error.message
         | Ok output -> Yojson.Safe.from_string output.content
       in
       check (option string) "proposal execution returns its identity"
         (Some (Proposal.Proposal_id.to_string proposal_id))
         (match field "proposal_id" execution_output with
          | Some (`String value) -> Some value
          | _ -> None);
       check (option string) "proposal execution returns its Assembler run"
         (Some run_id)
         (match field "assembler_run_id" execution_output with
          | Some (`String value) -> Some value
          | _ -> None);
       check (option string) "retained producer is verified"
         (Some "retained_match")
         (match field "proposal_provenance_status" execution_output with
          | Some (`String value) -> Some value
          | _ -> None);
       (match field "actions" execution_output with
        | Some (`List actions) ->
          check (list string) "stored plan executed the exact Tool sequence"
            [ "keeper_time_now"; "keeper_context_status"; "keeper_time_now" ]
            (List.map
               (function
                 | `Assoc action ->
                   (match List.assoc_opt "tool_name" action with
                    | Some (`String value) -> value
                    | _ -> fail "proposal action omitted tool_name")
                 | _ -> fail "proposal action was not an object")
               actions)
        | _ -> fail "proposal execution did not return typed actions");
       let rows =
         Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:8 ()
       in
       let summary_rows, node_rows =
         List.partition
           (fun row ->
              Safe_ops.json_string_opt "record_kind" row
              = Some "composition_run")
           rows
       in
       check int "one proposal composition summary row" 1
         (List.length summary_rows);
       check int "three proposal node rows" 3 (List.length node_rows);
       List.iter
         (fun row ->
            check (option string) "telemetry joins the Assembler run"
              (Some run_id)
              (Safe_ops.json_string_opt "assembler_run_id" row);
            check (option string) "telemetry joins the proposal"
              (Some (Proposal.Proposal_id.to_string proposal_id))
              (Safe_ops.json_string_opt "proposal_id" row);
            check (option string) "telemetry preserves retained verification"
              (Some "retained_match")
              (Safe_ops.json_string_opt "proposal_provenance_status" row);
            check (option string) "telemetry joins the parent Tool call"
              (Some "assembler-proposal-execute")
              (Safe_ops.json_string_opt "parent_tool_use_id" row))
         rows;
       let run_ids =
         List.filter_map
           (Safe_ops.json_string_opt "composition_run_id")
           rows
         |> List.sort_uniq String.compare
       in
       check int "summary and nodes share one composition run" 1
         (List.length run_ids);
       (match summary_rows with
        | [ summary ] ->
          check (option string) "summary preserves completed disposition"
            (Some "completed")
            (Safe_ops.json_string_opt "disposition" summary)
        | _ -> assert false);
       let failed_proposal =
         match
           Proposal.create
             ~descriptors:(Surface.descriptors capability_surface)
             ~objective:"Reject an invalid current-time input before dispatch"
             ~execution:Proposal.Inline
             ~capability_surface_sha256:(Surface.digest capability_surface)
             ~ordinary_tool_references:[ time_reference ]
             ~plan_json:
               (`Assoc
                 [ ( "nodes"
                   , `List
                       [ `Assoc
                           [ "id", `String "invalid-clock"
                           ; "tool", `String "keeper_time_now"
                           ; ( "input"
                             , `Assoc
                                 [ "kind", `String "literal"
                                 ; ( "value"
                                   , `Assoc [ "unexpected", `Bool true ] )
                                 ] )
                           ] ] )
                 ])
         with
         | Ok proposal -> proposal
         | Error error ->
           failf "failed proposal fixture rejected before execution: %s"
             (Proposal.error_to_yojson error |> Yojson.Safe.to_string)
       in
       (match Store.save config failed_proposal with
        | Ok Store.Stored | Ok Store.Already_present -> ()
        | Error error ->
          failf "failed proposal fixture did not persist: %s"
            (Store.error_to_yojson error |> Yojson.Safe.to_string));
       let failed_proposal_id =
         Proposal.id failed_proposal |> Proposal.Proposal_id.to_string
       in
       let failed_request =
         `Assoc
           [ "assembler_run_id", `String "failed-producer-not-retained"
           ; "proposal_id", `String failed_proposal_id
           ; "approval_tools", `List [ `String "keeper_time_now" ]
           ]
       in
       (match
          Agent_core.Tool.execute
            ~invocation:(invocation "assembler-proposal-failed")
            proposal_tool
            failed_request
        with
        | Ok _ -> fail "invalid proposal input unexpectedly executed"
        | Error error ->
          let payload =
            Yojson.Safe.from_string error.message
            |> Yojson.Safe.Util.member "masc.payload"
          in
          check (option string) "failed response retains producer identity"
            (Some "failed-producer-not-retained")
            (match field "assembler_run_id" payload with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "failed response retains proposal identity"
            (Some failed_proposal_id)
            (match field "proposal_id" payload with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "failed response retains provenance status"
            (Some "not_retained")
            (match field "proposal_provenance_status" payload with
             | Some (`String value) -> Some value
             | _ -> None));
       let failed_rows =
         Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:8 ()
         |> List.filter (fun row ->
           Safe_ops.json_string_opt "proposal_id" row
           = Some failed_proposal_id)
       in
       (match failed_rows with
        | [ summary ] ->
          check (option string) "failed proposal records one terminal summary"
            (Some "composition_run")
            (Safe_ops.json_string_opt "record_kind" summary);
          check (option string) "failed proposal summary is failed"
            (Some "failed")
            (Safe_ops.json_string_opt "disposition" summary)
        | rows ->
          failf "failed proposal recorded %d causal rows instead of one summary"
            (List.length rows));
       let board_tool = find_agent_core_tool bundle.tools "masc_board_list" in
       let board_revision =
         let board_invocation =
           Agent_core.Tool_contract.Invocation.create
             ~tool_use_id:"assembler-proposal-board-revision"
             ~turn:1
             ~schedule:
               { Agent_core.Tool_contract.planned_index = 0
               ; batch_index = 0
               ; batch_size = 1
               ; execution_mode = Agent_core.Tool_contract.Serial
               }
             ~completion:(Agent_core.Tool.completion board_tool)
         in
         match
           Agent_core.Tool.execute
             ~invocation:board_invocation
             board_tool
             (`Assoc [])
         with
         | Error error -> failf "board revision read failed: %s" error.message
         | Ok output ->
           Yojson.Safe.from_string output.content
           |> Yojson.Safe.Util.member "revision"
           |> Yojson.Safe.Util.to_string
       in
       let deferred_proposal =
         match
           Proposal.create
             ~descriptors:(Surface.descriptors capability_surface)
             ~objective:"Read the board only when its revision changes"
             ~execution:Proposal.Inline
             ~capability_surface_sha256:(Surface.digest capability_surface)
             ~ordinary_tool_references:[ board_reference ]
             ~plan_json:
               (`Assoc
                 [ ( "nodes"
                   , `List
                       [ `Assoc
                           [ "id", `String "unchanged-board"
                           ; "tool", `String "masc_board_list"
                           ; ( "input"
                             , `Assoc
                                 [ "kind", `String "literal"
                                 ; ( "value"
                                   , `Assoc
                                       [ "if_revision", `String board_revision ] )
                                 ] )
                           ] ] )
                 ])
         with
         | Ok proposal -> proposal
         | Error error ->
           failf "deferred proposal fixture rejected before execution: %s"
             (Proposal.error_to_yojson error |> Yojson.Safe.to_string)
       in
       (match Store.save config deferred_proposal with
        | Ok Store.Stored | Ok Store.Already_present -> ()
        | Error error ->
          failf "deferred proposal fixture did not persist: %s"
            (Store.error_to_yojson error |> Yojson.Safe.to_string));
       let deferred_proposal_id =
         Proposal.id deferred_proposal |> Proposal.Proposal_id.to_string
       in
       let deferred_request =
         `Assoc
           [ "assembler_run_id", `String "deferred-producer-not-retained"
           ; "proposal_id", `String deferred_proposal_id
           ; "approval_tools", `List [ `String "masc_board_list" ]
           ]
       in
       (match
          Agent_core.Tool.execute
            ~invocation:(invocation "assembler-proposal-deferred")
            proposal_tool
            deferred_request
        with
        | Error error -> failf "deferred proposal returned Error: %s" error.message
        | Ok output ->
          let payload = Yojson.Safe.from_string output.content in
          check (option string) "deferred response retains producer identity"
            (Some "deferred-producer-not-retained")
            (match field "assembler_run_id" payload with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "deferred response retains proposal identity"
            (Some deferred_proposal_id)
            (match field "proposal_id" payload with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "deferred response retains provenance status"
            (Some "not_retained")
            (match field "proposal_provenance_status" payload with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "Agent-Core keeps deferred disposition"
            (Some "deferred")
            (match output.Agent_core.Types._meta with
             | Some metadata ->
               (match field "masc.tool_disposition" metadata with
                | Some (`String value) -> Some value
                | _ -> None)
             | None -> None));
       let deferred_rows =
         Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:8 ()
         |> List.filter (fun row ->
           Safe_ops.json_string_opt "proposal_id" row
           = Some deferred_proposal_id)
       in
       let deferred_summaries, deferred_nodes =
         List.partition
           (fun row ->
              Safe_ops.json_string_opt "record_kind" row
              = Some "composition_run")
           deferred_rows
       in
       check int "deferred proposal records one terminal summary" 1
         (List.length deferred_summaries);
       check int "deferred proposal records one deferred node" 1
         (List.length deferred_nodes);
       (match deferred_summaries with
        | [ summary ] ->
          check (option string) "deferred summary keeps disposition"
            (Some "deferred")
            (Safe_ops.json_string_opt "disposition" summary)
        | _ -> assert false);
       check int "proposal execution does not recall the Assembler" 1
         (Fixture.post_count accepted))
;;

let test_model_visible_async_proposal_uses_durable_broker () =
  with_eio_base "assembler-model-visible-async"
  @@ fun ~sw ~net ~clock ~base_path:_ ~config ~request:_ ->
  let accepted =
    Fixture.start_server
      ~sw
      ~net
      ~clock
      (Fixture.Reply (Fixture.openai_response plan_output))
  in
  publish_lane
    [ { Fixture.id = "assembler-async-accepted"; base_url = accepted.base_url } ];
  let capability_surface = surface () in
  let time_reference = reference capability_surface "keeper_time_now" in
  let web_fetch_reference = reference capability_surface "WebFetch" in
  let meta = assembler_meta "assembler-async-tool-test" in
  let publication_recovery =
    { Keeper_publication_recovery_availability.provider =
        Keeper_publication_recovery_availability.non_runtime_provider
    ; keeper_name = meta.name
    }
  in
  let turn_ctx_cell = Keeper_tool_call_log.create_turn_ctx_cell () in
  (match
     Keeper_gate_mode.set
       config
       ~actor:"assembler-async-test"
       Keeper_gate_mode.Always_allow
   with
   | Ok _ -> ()
   | Error detail -> failf "failed to allow async WebFetch: %s" detail);
  Keeper_tool_call_log.set_turn_context
    ~cell:turn_ctx_cell
    ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
    ~session_id:"assembler-async-session"
    ~turn:1
    ();
  let bundle =
    Keeper_tools_agent_core_bundle.make_tool_bundle_for_capability_surface
      ~config
      ~meta
      ~publication_recovery
      ~ctx_snapshot:
        (Keeper_context_runtime.create
           ~eio:false
           ~system_prompt:"assembler async Tool test")
      ~clock
      ~turn_ctx_cell
      ~capability_surface
      ()
  in
  Fun.protect
    ~finally:(fun () ->
      bundle.cleanup ();
      Keeper_tool_call_log.reset_for_testing ())
    (fun () ->
       let invoke tool tool_use_id input =
         let invocation =
           Agent_core.Tool_contract.Invocation.create
             ~tool_use_id
             ~turn:1
             ~schedule:
               { Agent_core.Tool_contract.planned_index = 0
               ; batch_index = 0
               ; batch_size = 1
               ; execution_mode = Agent_core.Tool_contract.Serial
               }
             ~completion:(Agent_core.Tool.completion tool)
         in
         match Agent_core.Tool.execute ~invocation tool input with
         | Ok output -> Yojson.Safe.from_string output.content
         | Error error -> failf "%s failed: %s" tool.schema.name error.message
       in
       let assemble_tool = find_agent_core_tool bundle.tools "keeper_assemble_plan" in
       let assembled =
         invoke
           assemble_tool
           "assembler-async-propose"
           (`Assoc
             [ "objective", `String "Read the current time asynchronously"
             ; "execution", `String "async"
             ; ( "ordinary_tool_references"
               , `List
                   [ Surface.ordinary_tool_reference_to_yojson time_reference ] )
             ])
       in
       let proposal_id =
         match field "proposal_id" assembled with
         | Some (`String value) -> value
         | _ -> fail "async Assembler result omitted proposal_id"
       in
       let execution_request =
         match field "execution_request" assembled with
         | Some (`Assoc fields) ->
           `Assoc
             (List.map
                (fun (name, value) ->
                   if String.equal name "assembler_run_id"
                   then name, `String "assembler-run-not-retained"
                   else name, value)
                fields)
         | None -> fail "async Assembler result omitted execution_request"
         | Some _ -> fail "async execution_request was not an object"
       in
       let proposal_tool =
         find_agent_core_tool bundle.tools "keeper_proposal_execute"
       in
       Keeper_tool_call_log.reset_for_testing ();
       Keeper_tool_call_log.init ~base_path:config.base_path ();
       let submitted =
         invoke proposal_tool "assembler-async-execute" execution_request
       in
       check (option string) "async submission retains proposal identity"
         (Some proposal_id)
         (match field "proposal_id" submitted with
          | Some (`String value) -> Some value
          | _ -> None);
       check (option string) "async submission names durable execution mode"
         (Some "async")
         (match field "execution" submitted with
          | Some (`String value) -> Some value
          | _ -> None);
       check (option string) "retention eviction does not hard-gate async work"
         (Some "not_retained")
         (match field "proposal_provenance_status" submitted with
          | Some (`String value) -> Some value
          | _ -> None);
       let request_id =
         match field "request_id" submitted with
         | Some (`String value) -> value
         | _ -> fail "async submission omitted request_id"
       in
       let terminal =
         await_async_done ~clock ~config ~caller:meta.name request_id
       in
       check (option string) "durable terminal result retains proposal identity"
         (Some proposal_id)
         (match field "proposal_id" terminal with
          | Some (`String value) -> Some value
          | _ -> None);
       check (option string) "durable terminal retains Assembler run identity"
         (Some "assembler-run-not-retained")
         (match field "assembler_run_id" terminal with
          | Some (`String value) -> Some value
          | _ -> None);
       check (option string) "durable terminal retains provenance status"
         (Some "not_retained")
         (match field "proposal_provenance_status" terminal with
          | Some (`String value) -> Some value
          | _ -> None);
       (match field "actions" terminal with
        | Some (`List [ `Assoc action ]) ->
          check (option string) "async worker executed the stored Tool"
            (Some "keeper_time_now")
            (match List.assoc_opt "tool_name" action with
             | Some (`String value) -> Some value
             | _ -> None)
        | _ -> fail "async terminal result omitted its typed action");
       let rows =
         Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:4 ()
       in
       check int "async execution records one summary and one node" 2
         (List.length rows);
       List.iter
         (fun row ->
            check (option string) "async telemetry preserves evicted producer id"
              (Some "assembler-run-not-retained")
              (Safe_ops.json_string_opt "assembler_run_id" row);
            check (option string) "async telemetry joins the proposal"
              (Some proposal_id)
              (Safe_ops.json_string_opt "proposal_id" row);
            check (option string) "async telemetry records unavailable provenance"
              (Some "not_retained")
              (Safe_ops.json_string_opt "proposal_provenance_status" row);
            check (option string) "async telemetry joins the parent Tool call"
              (Some "assembler-async-execute")
              (Safe_ops.json_string_opt "parent_tool_use_id" row))
         rows;
       check int "async telemetry shares one composition run" 1
         (rows
          |> List.filter_map
               (Safe_ops.json_string_opt "composition_run_id")
          |> List.sort_uniq String.compare
          |> List.length);
       let status_tool =
         find_agent_core_tool bundle.tools Catalog.status_tool_name
       in
       let status =
         invoke
           status_tool
           "assembler-async-status"
           (`Assoc [ "request_id", `String request_id ])
       in
       check (option string) "model-visible status reads durable completion"
         (Some "done")
         (match field "status" status with
          | Some (`String value) -> Some value
          | _ -> None);
       (match field "request_context" status with
        | Some context ->
          check (option string) "status retains accepted Assembler run"
            (Some "assembler-run-not-retained")
            (match field "assembler_run_id" context with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "status retains accepted proposal"
            (Some proposal_id)
            (match field "proposal_id" context with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "status retains accepted provenance"
            (Some "not_retained")
            (match field "proposal_provenance_status" context with
             | Some (`String value) -> Some value
             | _ -> None)
        | None -> fail "model-visible status omitted request_context");
       let fetch_started, resolve_fetch_started = Eio.Promise.create () in
       let release_fetch, resolve_release_fetch = Eio.Promise.create () in
       Tool_misc.with_web_fetch_http_get_for_test
         (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ _url ->
            ignore (Eio.Promise.try_resolve resolve_fetch_started ());
            Eio.Promise.await release_fetch;
            Ok (Some 200, "cancelled fixture response"))
       @@ fun () ->
       let cancelled_proposal =
         match
           Proposal.create
             ~descriptors:(Surface.descriptors capability_surface)
             ~objective:"Fetch one URL until the operator cancels it"
             ~execution:Proposal.Async
             ~capability_surface_sha256:(Surface.digest capability_surface)
             ~ordinary_tool_references:[ web_fetch_reference ]
             ~plan_json:
               (`Assoc
                 [ ( "nodes"
                   , `List
                       [ `Assoc
                           [ "id", `String "blocked-fetch"
                           ; "tool", `String "WebFetch"
                           ; ( "input"
                             , `Assoc
                                 [ "kind", `String "literal"
                                 ; ( "value"
                                   , `Assoc
                                       [ ( "url"
                                         , `String
                                             "https://example.com/blocked" )
                                       ] )
                                 ] )
                           ] ] )
                 ])
         with
         | Ok proposal -> proposal
         | Error error ->
           failf "cancel proposal fixture rejected: %s"
             (Proposal.error_to_yojson error |> Yojson.Safe.to_string)
       in
       (match Store.save config cancelled_proposal with
        | Ok Store.Stored | Ok Store.Already_present -> ()
        | Error error ->
          failf "cancel proposal fixture did not persist: %s"
            (Store.error_to_yojson error |> Yojson.Safe.to_string));
       let cancelled_proposal_id =
         Proposal.id cancelled_proposal |> Proposal.Proposal_id.to_string
       in
       let cancelled_submission =
         invoke
           proposal_tool
           "assembler-async-cancel-submit"
           (`Assoc
             [ "assembler_run_id", `String "assembler-cancel-not-retained"
             ; "proposal_id", `String cancelled_proposal_id
             ; "approval_tools", `List [ `String "WebFetch" ]
             ])
       in
       let cancelled_request_id =
         match field "request_id" cancelled_submission with
         | Some (`String value) -> value
         | _ -> fail "cancel proposal submission omitted request_id"
       in
       Eio.Time.with_timeout_exn clock 5.0 (fun () ->
         Eio.Promise.await fetch_started);
       let cancel_tool =
         find_agent_core_tool bundle.tools Catalog.cancel_tool_name
       in
       let cancellation =
         invoke
           cancel_tool
           "assembler-async-cancel"
           (`Assoc [ "request_id", `String cancelled_request_id ])
       in
       check (option string) "cancel Tool accepts the exact request"
         (Some "cancelling")
         (match field "status" cancellation with
          | Some (`String value) -> Some value
          | _ -> None);
       let cancelled_entry =
         Eio.Time.with_timeout_exn clock 5.0 (fun () ->
           let rec loop () =
             match
               Async.poll
                 ~base_path:config.base_path
                 ~caller:meta.name
                 cancelled_request_id
             with
             | Async.Found
                 ({ status = Async.Cancelled _; _ } as entry) -> entry
             | Async.Found
                 { status = (Async.Queued | Async.Running | Async.Cancelling _); _ }
               ->
               Eio.Fiber.yield ();
               loop ()
             | Async.Found { status; _ } ->
               failf "cancelled proposal reached %s"
                 (Async.status_to_string status)
             | Async.Absent -> fail "cancelled proposal disappeared"
             | Async.Unreadable detail ->
               failf "cancelled proposal became unreadable: %s" detail
             | Async.Rejected _ -> fail "cancelled proposal ownership rejected"
           in
           loop ())
       in
       Eio.Promise.resolve resolve_release_fetch ();
       (match cancelled_entry.Async.request_context with
        | Some fields ->
          let context = `Assoc fields in
          check (option string) "cancelled terminal retains Assembler run"
            (Some "assembler-cancel-not-retained")
            (match field "assembler_run_id" context with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "cancelled terminal retains proposal"
            (Some cancelled_proposal_id)
            (match field "proposal_id" context with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "cancelled terminal retains provenance"
            (Some "not_retained")
            (match field "proposal_provenance_status" context with
             | Some (`String value) -> Some value
             | _ -> None)
        | None -> fail "cancelled terminal omitted request context");
       Eio.Time.with_timeout_exn clock 5.0 (fun () ->
         let rec await_switch_release () =
           if Async.For_testing.active_switch_count () = 0
           then ()
           else (
             Eio.Fiber.yield ();
             await_switch_release ())
         in
         await_switch_release ());
       check int "cancelled worker releases its request switch" 0
         (Async.For_testing.active_switch_count ());
       let cancelled_status =
         invoke
           status_tool
           "assembler-async-cancel-status"
           (`Assoc [ "request_id", `String cancelled_request_id ])
       in
       check (option string) "status reports durable cancellation"
         (Some "cancelled")
         (match field "status" cancelled_status with
          | Some (`String value) -> Some value
          | _ -> None);
       let cancellation_summaries =
         Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:8 ()
         |> List.filter (fun row ->
           Safe_ops.json_string_opt "record_kind" row
           = Some "composition_run"
           && Safe_ops.json_string_opt "proposal_id" row
              = Some cancelled_proposal_id)
       in
       check int "cancelled proposal records one summary" 1
         (List.length cancellation_summaries);
       check int "async execution does not recall the Assembler" 1
         (Fixture.post_count accepted))
;;

let test_compatibility_path_requires_frozen_surface () =
  let result =
    Keeper_tool_assemble_plan_runtime.handle_without_frozen_surface ()
  in
  (match result.disposition with
   | Tool_result.Failed Tool_result.Policy_rejection -> ()
   | Tool_result.Completed () | Tool_result.Deferred () | Tool_result.Failed _ ->
     fail "compatibility path did not return a policy rejection");
  check bool "compatibility refusal is proven pre-effect" true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect);
  let data = Option.value result.data ~default:`Null in
  check (option string) "typed frozen-surface refusal"
    (Some "frozen_surface_required")
    (match field "error" data with
     | Some (`String value) -> Some value
     | _ -> None)
;;

let test_model_visible_runtime_reports_missing_net_before_setup () =
  with_temp_base @@ fun base_path ->
  let capability_surface = surface () in
  let reference = reference capability_surface "keeper_time_now" in
  let args =
    `Assoc
      [ "objective", `String "Read the current time"
      ; "execution", `String "inline"
      ; ( "ordinary_tool_references"
        , `List [ Surface.ordinary_tool_reference_to_yojson reference ] )
      ]
  in
  let result =
    Keeper_tool_assemble_plan_runtime.handle
      ~capability_surface
      ~config:(Workspace.default_config_uncached base_path)
      ~keeper_name:"assembler-no-net"
      ~args
      ()
  in
  (match result.disposition with
   | Tool_result.Failed Tool_result.Runtime_failure -> ()
   | Tool_result.Completed () | Tool_result.Deferred () | Tool_result.Failed _ ->
     fail "missing net did not return a runtime failure");
  check bool "missing net is proven pre-effect" true
    (result.failure_effect_disposition = Tool_result.Proven_pre_effect);
  let data = Option.value result.data ~default:`Null in
  check (option string) "typed missing-net error"
    (Some "assembler_runtime_resource_unavailable")
    (match field "error" data with
     | Some (`String value) -> Some value
     | _ -> None);
  check (option string) "typed missing resource" (Some "eio_net")
    (match field "resource" data with
     | Some (`String value) -> Some value
     | _ -> None)
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
        ; test_case
            "model-visible Tool stores a proposal without Tool execution"
            `Quick
            test_model_visible_tool_produces_proposal_without_tool_execution
        ; test_case
            "model-visible async proposal uses the durable broker"
            `Quick
            test_model_visible_async_proposal_uses_durable_broker
        ; test_case
            "compatibility path requires the frozen surface"
            `Quick
            test_compatibility_path_requires_frozen_surface
        ; test_case
            "missing net is typed before Assembler setup"
            `Quick
            test_model_visible_runtime_reports_missing_net_before_setup
        ] )
    ]
;;
