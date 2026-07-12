(* RFC-0266 Phase 1 — fusion async-completion wake + actionable delivery.

   The wake (Fusion_sink.wake_keeper_on_fusion_completion -> wakeup_keeper) needs
   a live registry, so it is exercised end-to-end at runtime rather than here.
   These unit checks pin the two compile-passing-but-silently-wrong failure
   modes a stub could introduce:

   1. the closed-sum helpers must classify the new [Fusion_completed] variant
      (label / is_board_signal / reaction-ledger kind); and
   2. a completed fusion must become a NON-EMPTY [pending_board_event] carrying
      the resolved answer — returning [] (like the Bootstrap/No_progress_recovery
      arms) would compile but silently drop the result, defeating the RFC. *)

open Alcotest
open Masc

(* substring check without pulling in the [str] library *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.equal (String.sub haystack i nl) needle || go (i + 1)) in
  nl = 0 || go 0
;;

let assoc_fields label = function
  | `Assoc fields -> fields
  | json ->
    fail
      (Printf.sprintf "%s: expected JSON object, got %s" label
         (Yojson.Safe.to_string json))
;;

let field label fields key =
  match List.assoc_opt key fields with
  | Some value -> value
  | None -> fail (Printf.sprintf "%s: missing field %s" label key)
;;

let string_field label fields key =
  match field label fields key with
  | `String value -> value
  | json ->
    fail
      (Printf.sprintf "%s.%s: expected string, got %s" label key
         (Yojson.Safe.to_string json))
;;

let int_field label fields key =
  match field label fields key with
  | `Int value -> value
  | json ->
    fail
      (Printf.sprintf "%s.%s: expected int, got %s" label key
         (Yojson.Safe.to_string json))
;;

let bool_field label fields key =
  match field label fields key with
  | `Bool value -> value
  | json ->
    fail
      (Printf.sprintf "%s.%s: expected bool, got %s" label key
         (Yojson.Safe.to_string json))
;;

let list_field label fields key =
  match field label fields key with
  | `List values -> values
  | json ->
    fail
      (Printf.sprintf "%s.%s: expected list, got %s" label key
         (Yojson.Safe.to_string json))
;;
let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))
;;

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path
;;

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""
;;

(* Board_dispatch.create_post (via Fusion_sink.emit) needs a live Eio
   scheduler for its lock/cancellation-context effects (Effect.Unhandled
   (Eio.Cancel.Get_context) otherwise) — same [Eio_main.run] +
   [Fs_compat.set_fs] wrapper test_board_dispatch.ml's [with_eio] uses. *)
let with_isolated_eio_base_path prefix f =
  let base_dir = temp_base_path prefix in
  let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let old_registry = Fusion_run_registry.global () in
  Fun.protect
    ~finally:(fun () ->
      Fusion_run_registry.set_global old_registry;
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      restore_env "MASC_BASE_PATH" old_base;
      restore_env "MASC_BASE_PATH_INPUT" old_base_input;
      try remove_tree base_dir with _ -> ())
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Unix.putenv "MASC_BASE_PATH_INPUT" base_dir;
      Fusion_run_registry.set_global (Fusion_run_registry.create ());
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw -> f env sw base_dir)
;;

let with_isolated_base_path prefix f =
  with_isolated_eio_base_path prefix (fun _env _sw base_dir -> f base_dir)
;;

let make_meta ?(name = "fusion-keeper") () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ ("name", `String name)
         ; ("agent_name", `String name)
         ; ("trace_id", `String "test-trace-fusion")
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)
;;

let fusion_payload
      ?(run_id = "fus-1")
      ?(ok = true)
      ?(resolved_answer = "use approach B because it is reversible")
      ?(board_post_id = "post-77")
      ()
  : Keeper_event_queue.fusion_completion
  =
  { run_id; ok; resolved_answer; board_post_id }
;;

let fusion_stimulus ?run_id ?ok ?resolved_answer ?board_post_id () : Keeper_event_queue.stimulus =
  { post_id = "ignored-by-fusion-arm"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1000.0
  ; payload =
      Keeper_event_queue.Fusion_completed
        (fusion_payload ?run_id ?ok ?resolved_answer ?board_post_id ())
  }
;;

let judge_synthesis resolved_answer : Fusion_types.judge_synthesis =
  { consensus = []
  ; contradictions = []
  ; partial_coverage = []
  ; unique_insights = []
  ; blind_spots = []
  ; resolved_answer
  ; decision = Fusion_types.Answer resolved_answer
  }
;;

let validated_preset (preset : Fusion_policy.preset) : Fusion_policy.Validated_preset.t =
  match Fusion_policy.Validated_preset.of_preset preset with
  | Ok preset -> preset
  | Error _ -> fail "test setup: fusion preset literal failed validation"
;;

let fusion_tool_policy () : Fusion_policy.t =
  let panel_group : Fusion_policy.panel_group =
    { models = [ "panel.model" ]
    ; label = "panel"
    ; system_prompt = "panel system prompt"
    ; web_tools = false
    ; max_tool_calls = 0
    ; max_output_tokens = None
    ; timeout_s = Fusion_policy.default_timeout_s
    }
  in
  let preset : Fusion_policy.preset =
    { name = "unit"
    ; panels = [ panel_group ]
    ; judge = "judge.model"
    ; judge_system_prompt = "judge system prompt"
    ; judge_timeout_s = Fusion_policy.default_timeout_s
    ; judge_max_output_tokens = None
    ; meta_timeout_s = Fusion_policy.default_timeout_s
    ; judges = []
    ; min_answered = Fusion_policy.default_min_answered
    ; judge_wave_budget_s = Float.max_float
    ; adaptive_timeout_factor = 1.0
    ; fallback_judge_model = None
    }
  in
  { enabled = true
  ; default_preset = preset.name
  ; max_concurrent_panels = 1
  ; max_concurrent_judges = Fusion_policy.default_max_concurrent_judges
  ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
  ; presets = [ validated_preset preset ]
  }
;;

let bg_payload
      ?(bg_run_id = "bg-1")
      ?(bg_kind = Keeper_event_queue.Subprocess)
      ?(bg_outcome = Keeper_event_queue.Bg_ok "background output")
      ?(bg_board_post_id = "post-bg-1")
      ()
  : Keeper_event_queue.bg_job_completion
  =
  { bg_run_id; bg_kind; bg_outcome; bg_board_post_id }
;;

let bg_stimulus ?bg_run_id ?bg_kind ?bg_outcome ?bg_board_post_id ()
  : Keeper_event_queue.stimulus
  =
  { post_id = "ignored-by-bg-arm"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 2000.0
  ; payload =
      Keeper_event_queue.Bg_completed
        (bg_payload ?bg_run_id ?bg_kind ?bg_outcome ?bg_board_post_id ())
  }
;;

let scheduled_wake
      ?(schedule_id = "sched-1")
      ?(due_at = 3000.0)
      ?(payload_digest = "digest-1")
      ?(title = Some "Scheduled lane wake")
      ?(message = "SCHEDULE-ANSWER-TOKEN")
      ()
  : Keeper_event_queue.scheduled_wake
  =
  { schedule_id; due_at; payload_digest; title; message }
;;

let schedule_stimulus ?schedule_id ?due_at ?payload_digest ?title ?message ()
  : Keeper_event_queue.stimulus
  =
  let wake = scheduled_wake ?schedule_id ?due_at ?payload_digest ?title ?message () in
  { post_id = Keeper_event_queue.schedule_due_post_id wake
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 3000.0
  ; payload = Keeper_event_queue.Schedule_due wake
  }
;;

(* (1) closed-sum helpers classify the new variant *)
let test_closed_sum_helpers () =
  let p = Keeper_event_queue.Fusion_completed (fusion_payload ()) in
  check string "payload_kind_label" "fusion_completed" (Keeper_event_queue.payload_kind_label p);
  check bool "is_board_signal is false" false (Keeper_event_queue.is_board_signal p);
  check
    string
    "reaction_ledger stimulus_kind_to_string"
    "fusion_completed"
    (Keeper_reaction_ledger.stimulus_kind_to_string Keeper_reaction_ledger.Fusion_completed)
;;

(* (2) THE behavioral guard: a completed fusion becomes a non-empty actionable
   pending_board_event that carries the resolved answer. *)
let test_fusion_completion_is_actionable () =
  let meta = make_meta () in
  let fc = fusion_payload ~resolved_answer:"ANSWER-TOKEN-xyz" ~board_post_id:"post-77" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion
      ~meta
      ~arrived_at:1000.0
      fc
  in
  check string "post_id correlates to the board post" "post-77" ev.post_id;
  check bool "preview carries the resolved answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview);
  (* RFC-0247: a self-authored System_post fusion result renders observationally,
     not as trusted operator instruction. *)
  check
    bool
    "provenance is Self_narrative"
    true
    (match ev.provenance with
     | Keeper_world_observation.Self_narrative -> true
     | _ -> false);
  (* the stimulus path yields Some (not None like Bootstrap/No_progress_recovery) *)
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (fusion_stimulus ~resolved_answer:"ANSWER-TOKEN-xyz" ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check bool "stimulus path preview carries the answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview)
  | None -> fail "Fusion_completed stimulus must produce Some pending_board_event, not None"
;;

(* RFC-0290: a completed background job follows the same non-empty delivery
   contract as Fusion_completed. *)
let test_bg_completion_is_actionable () =
  let meta = make_meta ~name:"bg-keeper" () in
  let bg =
    bg_payload
      ~bg_run_id:"bg-42"
      ~bg_outcome:(Keeper_event_queue.Bg_ok "BG-ANSWER-TOKEN")
      ~bg_board_post_id:"post-bg-42"
      ()
  in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_bg_job_completion
      ~meta
      ~arrived_at:2000.0
      bg
  in
  check string "post_id correlates to the board post" "post-bg-42" ev.post_id;
  check
    bool
    "title names the background subprocess completion"
    true
    (contains ~needle:"Background subprocess complete" ev.title);
  check
    bool
    "preview carries the background output"
    true
    (contains ~needle:"BG-ANSWER-TOKEN" ev.preview);
  check
    bool
    "provenance is Self_narrative"
    true
    (match ev.provenance with
     | Keeper_world_observation.Self_narrative -> true
     | _ -> false);
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (bg_stimulus ~bg_outcome:(Keeper_event_queue.Bg_ok "BG-ANSWER-TOKEN") ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check
      bool
      "stimulus path preview carries the background output"
      true
      (contains ~needle:"BG-ANSWER-TOKEN" ev.preview)
  | None -> fail "Bg_completed stimulus must produce Some pending_board_event, not None"
;;

let test_bg_failure_missing_board_post_id_fallback () =
  let meta = make_meta ~name:"bg-keeper" () in
  let bg =
    bg_payload
      ~bg_run_id:"bg-9"
      ~bg_outcome:(Keeper_event_queue.Bg_failed "exit status 127")
      ~bg_board_post_id:""
      ()
  in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_bg_job_completion
      ~meta
      ~arrived_at:2000.0
      bg
  in
  check string "synthetic fallback post id" "bg-run:bg-9" ev.post_id;
  check bool "title marks failure" true (contains ~needle:"failed" ev.title);
  check
    bool
    "preview carries failure reason"
    true
    (contains ~needle:"exit status 127" ev.preview)
;;

let test_scheduled_wake_is_actionable () =
  let meta = make_meta ~name:"schedule-keeper" () in
  let wake = scheduled_wake ~message:"SCHEDULE-ANSWER-TOKEN" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_scheduled_wake
      ~meta
      ~arrived_at:3000.0
      wake
  in
  check string "post_id correlates to schedule" "schedule-due:sched-1" ev.post_id;
  check bool "preview carries schedule message" true
    (contains ~needle:"SCHEDULE-ANSWER-TOKEN" ev.preview);
  check bool "provenance is Automation" true
    (match ev.provenance with
     | Keeper_world_observation.Automation -> true
     | _ -> false);
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (schedule_stimulus ~message:"SCHEDULE-ANSWER-TOKEN" ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check bool "stimulus path preview carries the schedule message" true
      (contains ~needle:"SCHEDULE-ANSWER-TOKEN" ev.preview)
  | None -> fail "Schedule_due stimulus must produce Some pending_board_event, not None"
;;

(* (3) an empty board_post_id (sink failed to create the post) still delivers
   the answer under a synthetic, non-empty post id. *)
let test_missing_board_post_id_fallback () =
  let meta = make_meta () in
  let fc = fusion_payload ~run_id:"fus-9" ~board_post_id:"" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion ~meta ~arrived_at:1.0 fc
  in
  check string "synthetic fallback post id" "fusion-run:fus-9" ev.post_id
;;

let test_emit_success_projects_board_chat_and_registry () =
  with_isolated_base_path "fusion-success-sink" (fun base_dir ->
    let config = Workspace.default_config base_dir in
    let keeper = "fusion-keeper" in
    let run_id = Printf.sprintf "fus-success-%d" (Random.bits ()) in
    let question = "Which implementation should ship?" in
    let resolved_answer = "Ship the typed-origin path." in
    let panel_usage = { Fusion_types.input_tokens = 11; output_tokens = 13 } in
    let judge_usage = { Fusion_types.input_tokens = 17; output_tokens = 19 } in
    let synthesis = judge_synthesis resolved_answer in
    let panel =
      [ Fusion_types.Answered
          { model = "skeptic (claude)"
          ; answer = "typed origin keeps the dashboard honest"
          ; usage = panel_usage
          }
      ]
    in
    let judges =
      [ Fusion_types.Synthesized
          { role = Fusion_types.Single; synthesis; usage = judge_usage }
      ]
    in
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id ~keeper
      ~preset:"unit-test" ~started_at:2.0;
    let result =
      Fusion_sink.emit ~config ~base_dir ~keeper ~run_id ~question ~panel
        ~judge:(Ok synthesis) ~judges ~judge_usage
    in
    check bool "emit succeeds" true (Result.is_ok result);
    let post =
      match Board.find_post_by_run_id (Board.global ()) ~run_id with
      | Some post -> post
      | None -> fail "fusion board post should be indexed by typed origin.fusion_run_id"
    in
    let post_id = Board.Post_id.to_string post.id in
    (match post.origin with
     | Some origin ->
       check (option string) "origin.source" (Some "fusion") origin.source;
       check (option string) "origin.fusion_run_id" (Some run_id) origin.fusion_run_id;
       check bool "origin.turn_ref is not fabricated" true (Option.is_none origin.turn_ref)
     | None -> fail "fusion board post should carry typed origin");
    let meta =
      match post.meta_json with
      | Some json -> assoc_fields "board.meta" json
      | None -> fail "fusion board post should carry meta_json"
    in
    check string "meta.source" "fusion" (string_field "board.meta" meta "source");
    check string "meta.run_id" run_id (string_field "board.meta" meta "run_id");
    check string "meta.question" question (string_field "board.meta" meta "question");
    (match list_field "board.meta" meta "panel" with
     | [ panel_json ] ->
       let p = assoc_fields "board.meta.panel[0]" panel_json in
       check string "panel model" "skeptic (claude)"
         (string_field "board.meta.panel[0]" p "model");
       check string "panel status" "answered"
         (string_field "board.meta.panel[0]" p "status")
     | other -> fail (Printf.sprintf "expected exactly one panel row, got %d" (List.length other)));
    let judge = assoc_fields "board.meta.judge" (field "board.meta" meta "judge") in
    check string "judge status" "synthesized"
      (string_field "board.meta.judge" judge "status");
    check string "judge resolved answer" resolved_answer
      (string_field "board.meta.judge" judge "resolved_answer");
    (match list_field "board.meta" meta "judges" with
     | [ judge_json ] ->
       let j = assoc_fields "board.meta.judges[0]" judge_json in
       check string "judge node role" "single"
         (string_field "board.meta.judges[0]" j "role");
       check int "judge node input tokens" judge_usage.input_tokens
         (int_field "board.meta.judges[0]" j "input_tokens")
     | other ->
       fail (Printf.sprintf "expected exactly one judge node, got %d" (List.length other)));
    let observed_usage =
      assoc_fields "board.meta.observed_usage" (field "board.meta" meta "observed_usage")
    in
    check int "observed input tokens" (panel_usage.input_tokens + judge_usage.input_tokens)
      (int_field "board.meta.observed_usage" observed_usage "input_tokens");
    check int "observed output tokens" (panel_usage.output_tokens + judge_usage.output_tokens)
      (int_field "board.meta.observed_usage" observed_usage "output_tokens");
    let dashboard_json =
      Board_dispatch.post_to_yojson_with_karma post ~author_karma:0
      |> assoc_fields "dashboard.post"
    in
    let dashboard_origin =
      assoc_fields "dashboard.post.origin" (field "dashboard.post" dashboard_json "origin")
    in
    check string "dashboard origin source" "fusion"
      (string_field "dashboard.post.origin" dashboard_origin "source");
    check string "dashboard origin run id" run_id
      (string_field "dashboard.post.origin" dashboard_origin "fusion_run_id");
    let dashboard_meta =
      assoc_fields "dashboard.post.meta" (field "dashboard.post" dashboard_json "meta")
    in
    check string "dashboard meta run id" run_id
      (string_field "dashboard.post.meta" dashboard_meta "run_id");
    let messages = Keeper_chat_store.load ~base_dir ~keeper_name:keeper in
    let fusion_block =
      List.find_map
        (fun (m : Keeper_chat_store.chat_message) ->
           if contains ~needle:resolved_answer m.content
           then (
             match m.blocks with
             | Some blocks ->
               List.find_map
                 (function
                   | Keeper_chat_blocks.Fusion { board_post_id; run_id } ->
                     Some (board_post_id, run_id)
                   | _ -> None)
                 blocks
             | None -> None)
           else None)
        messages
    in
    (match fusion_block with
     | Some (block_post_id, block_run_id) ->
       check string "chat fusion block post id" post_id block_post_id;
       check string "chat fusion block run id" run_id block_run_id
     | None -> fail "chat lane should carry a Fusion block for the board evidence");
    match Fusion_run_registry.get (Fusion_run_registry.global ()) ~run_id with
    | Some { Fusion_run_registry.status = Completed { ok = true; _ }; _ } -> ()
    | Some { Fusion_run_registry.status = Completed { ok = false; _ }; _ } ->
      fail "fusion run should complete ok=true"
    | Some { Fusion_run_registry.status = Running; _ } ->
      fail "fusion run should not remain running"
    | None -> fail "fusion run should remain visible")
;;

let test_tool_handle_async_success_projects_running_then_completed () =
  with_isolated_eio_base_path "fusion-tool-async-success" (fun env sw base_dir ->
    let keeper = "fusion-tool-keeper" in
    let run_id = Printf.sprintf "fus-tool-success-%d" (Random.bits ()) in
    let question = "Which async fusion path should ship?" in
    let resolved_answer = "Ship the async handler path with typed sink evidence." in
    let panel_usage = { Fusion_types.input_tokens = 23; output_tokens = 29 } in
    let judge_usage = { Fusion_types.input_tokens = 31; output_tokens = 37 } in
    let synthesis = judge_synthesis resolved_answer in
    let panel =
      [ Fusion_types.Answered
          { model = "panel (panel.model)"
          ; answer = "the handler returns before background delivery"
          ; usage = panel_usage
          }
      ]
    in
    let judges =
      [ Fusion_types.Synthesized
          { role = Fusion_types.Single; synthesis; usage = judge_usage }
      ]
    in
    let release_promise, resolve_release = Eio.Promise.create () in
    let completed_promise, resolve_completed = Eio.Promise.create () in
    let config = Workspace.default_config base_dir in
    let run_orchestrator ~sw:_ ~net:_ ~config ~base_dir ~policy:_ ~topology:_
        ~request () =
      Eio.Promise.await release_promise;
      let outcome =
        match
          Fusion_sink.emit ~config ~base_dir
            ~keeper:request.Fusion_types.keeper
            ~run_id:request.Fusion_types.run_id ~question:request.Fusion_types.prompt
            ~panel ~judge:(Ok synthesis) ~judges ~judge_usage
        with
        | Ok () -> Fusion_orchestrator.Completed { panel; judge = Ok synthesis }
        | Error msg -> Fusion_orchestrator.Sink_failed msg
      in
      Eio.Promise.resolve resolve_completed outcome;
      outcome
    in
    let response =
      Fusion_tool.For_test.handle_with_runner ~run_orchestrator ~sw
        ~net:(Eio.Stdenv.net env) ~config ~base_dir ~keeper ~now_unix:4.0
        ~run_id
        ~policy:(fusion_tool_policy ())
        ~args:(`Assoc [ ("prompt", `String question) ])
    in
    let response_fields =
      Yojson.Safe.from_string response |> assoc_fields "fusion_tool.response"
    in
    check bool "handle response ok" true
      (bool_field "fusion_tool.response" response_fields "ok");
    check string "handle response status" "fusion_started"
      (string_field "fusion_tool.response" response_fields "status");
    check string "handle response run_id" run_id
      (string_field "fusion_tool.response" response_fields "run_id");
    check bool "delivery tells keeper not to poll" true
      (contains
         ~needle:"No need to poll masc_fusion_status"
         (string_field "fusion_tool.response" response_fields "delivery"));
    (match Fusion_run_registry.get (Fusion_run_registry.global ()) ~run_id with
     | Some { keeper = observed_keeper; preset; status = Fusion_run_registry.Running; _ } ->
       check string "running keeper" keeper observed_keeper;
       check string "running preset" "unit" preset
     | Some { Fusion_run_registry.status = Completed _; _ } ->
       fail "fusion run should still be Running before the background runner is released"
     | None -> fail "fusion run should be registered as Running before completion");
    Eio.Promise.resolve resolve_release ();
    (match
       Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 (fun () ->
         Eio.Promise.await completed_promise)
     with
     | Fusion_orchestrator.Completed { panel = observed_panel; judge = Ok observed_judge } ->
       check int "completed panel count" 1 (List.length observed_panel);
       check string "completed resolved answer" resolved_answer observed_judge.resolved_answer
     | Fusion_orchestrator.Completed { judge = Error _; _ } ->
       fail "background runner should complete with a synthesized judge"
     | Fusion_orchestrator.Denied _ -> fail "background runner should not deny"
     | Fusion_orchestrator.Sink_failed msg ->
       fail (Printf.sprintf "background runner sink failed: %s" msg));
    let post =
      match Board.find_post_by_run_id (Board.global ()) ~run_id with
      | Some post -> post
      | None -> fail "background success should create a board post indexed by run_id"
    in
    let post_id = Board.Post_id.to_string post.id in
    (match post.origin with
     | Some origin ->
       check (option string) "origin.source" (Some "fusion") origin.source;
       check (option string) "origin.fusion_run_id" (Some run_id) origin.fusion_run_id
     | None -> fail "background success board post should carry typed origin");
    let dashboard_json =
      Board_dispatch.post_to_yojson_with_karma post ~author_karma:0
      |> assoc_fields "dashboard.post"
    in
    let dashboard_origin =
      assoc_fields "dashboard.post.origin" (field "dashboard.post" dashboard_json "origin")
    in
    check string "dashboard origin run id" run_id
      (string_field "dashboard.post.origin" dashboard_origin "fusion_run_id");
    let messages = Keeper_chat_store.load ~base_dir ~keeper_name:keeper in
    let fusion_block =
      List.find_map
        (fun (m : Keeper_chat_store.chat_message) ->
           if contains ~needle:resolved_answer m.content
           then (
             match m.blocks with
             | Some blocks ->
               List.find_map
                 (function
                   | Keeper_chat_blocks.Fusion { board_post_id; run_id } ->
                     Some (board_post_id, run_id)
                   | _ -> None)
                 blocks
             | None -> None)
           else None)
        messages
    in
    (match fusion_block with
     | Some (block_post_id, block_run_id) ->
       check string "chat fusion block post id" post_id block_post_id;
       check string "chat fusion block run id" run_id block_run_id
     | None -> fail "chat lane should carry a Fusion block after async completion");
    match Fusion_run_registry.get (Fusion_run_registry.global ()) ~run_id with
    | Some { Fusion_run_registry.status = Completed { ok = true; _ }; _ } -> ()
    | Some { Fusion_run_registry.status = Completed { ok = false; _ }; _ } ->
      fail "fusion run should complete ok=true"
    | Some { Fusion_run_registry.status = Running; _ } ->
      fail "fusion run should not remain Running after background success"
    | None -> fail "fusion run should remain visible after background success")
;;
let test_emit_board_failure_is_best_effort () =
  with_isolated_base_path "fusion-board-best-effort" (fun base_dir ->
    let config = Workspace.default_config base_dir in
    let keeper = "bad/keeper" in
    let run_id = Printf.sprintf "fus-board-fail-%d" (Random.bits ()) in
    let resolved_answer = "BOARD-BEST-EFFORT-ANSWER" in
    Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id ~keeper
      ~preset:"unit-test" ~started_at:1.0;
    let result =
      Fusion_sink.emit ~config ~base_dir ~keeper ~run_id ~question:"q" ~panel:[]
        ~judge:(Ok (judge_synthesis resolved_answer)) ~judges:[]
        ~judge_usage:Fusion_types.zero_usage
    in
    check bool "board failure does not fail emit" true (Result.is_ok result);
    (match Fusion_run_registry.get (Fusion_run_registry.global ()) ~run_id with
     | Some run ->
       (match run.Fusion_run_registry.status with
        | Fusion_run_registry.Completed { ok = true; _ } -> ()
        | Fusion_run_registry.Completed { ok = false; _ } ->
          fail "fusion run should complete with ok=true"
        | Fusion_run_registry.Running -> fail "fusion run should not remain running")
     | None -> fail "fusion run should remain visible");
    let messages = Keeper_chat_store.load ~base_dir ~keeper_name:keeper in
    (* Keeper_chat_store.encode_line auto-derives blocks from message content
       for assistant rows when the caller passes [blocks:None] (RFC-0235 P3),
       so [m.blocks] is not [None] here — the check is that no *Fusion* card
       (which would point at the board post that failed to be created) is
       among whatever blocks got auto-derived. *)
    let answer_without_card =
      List.exists
        (fun (m : Keeper_chat_store.chat_message) ->
           contains ~needle:resolved_answer m.content
           &&
           match m.blocks with
           | None -> true
           | Some blocks ->
             not
               (List.exists
                  (function
                    | Keeper_chat_blocks.Fusion _ -> true
                    | _ -> false)
                  blocks))
        messages
    in
    check bool "chat lane receives answer without fusion card block" true answer_without_card)
;;

let () =
  run
    "fusion_wake"
    [ ( "rfc-0266"
      , [ test_case "closed-sum helpers classify Fusion_completed" `Quick test_closed_sum_helpers
        ; test_case
            "fusion completion is actionable (non-empty, carries answer)"
            `Quick
            test_fusion_completion_is_actionable
        ; test_case
            "missing board_post_id falls back to fusion-run id"
            `Quick
            test_missing_board_post_id_fallback
        ; test_case
            "emit success projects board, chat block, and registry"
            `Quick
            test_emit_success_projects_board_chat_and_registry
        ; test_case
            "tool handle returns Running then async success projects evidence"
            `Quick
            test_tool_handle_async_success_projects_running_then_completed
        ; test_case
            "emit treats board post failure as best-effort"
            `Quick
            test_emit_board_failure_is_best_effort
        ; test_case
            "background completion is actionable (non-empty, carries output)"
            `Quick
            test_bg_completion_is_actionable
        ; test_case
            "background failure falls back to bg-run id"
            `Quick
            test_bg_failure_missing_board_post_id_fallback
        ; test_case
            "scheduled wake is actionable (non-empty, carries message)"
            `Quick
            test_scheduled_wake_is_actionable
        ] )
    ]
;;
