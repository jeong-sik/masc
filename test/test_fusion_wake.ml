(* RFC-0266 Phase 1 — fusion async-completion wake + actionable delivery.

   The wake (Fusion_sink.wake_keeper_on_fusion_completion -> wakeup_keeper) needs
   a live registry, so it is exercised end-to-end at runtime rather than here.
   These unit checks pin the two compile-passing-but-silently-wrong failure
   modes a stub could introduce:

   1. the closed-sum helpers must classify the new [Fusion_completed] variant
      (label / is_board_signal / reaction-ledger kind); and
   2. a completed fusion must become a NON-EMPTY [pending_board_event] carrying
      the resolved answer — returning [] (like the Bootstrap
      arms) would compile but silently drop the result, defeating the RFC. *)

open Alcotest
open Masc

module Event_queue_persistence_source = Keeper_event_queue_persistence
module Keeper_event_queue_persistence = struct
  include Event_queue_persistence_source

  let load ~base_path ~keeper_name =
    match load_result ~base_path ~keeper_name with
    | Ok queue -> queue
    | Error detail -> fail detail
  ;;
end

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

let number_field label fields key =
  match field label fields key with
  | `Float value -> value
  | `Int value -> Float.of_int value
  | json ->
    fail
      (Printf.sprintf "%s.%s: expected number, got %s" label key
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

(* Fusion_sink's Board projection needs a live Eio scheduler for its
   lock/cancellation-context effects (Effect.Unhandled
   (Eio.Cancel.Get_context) otherwise) — same [Eio_main.run] +
   [Fs_compat.set_fs] wrapper test_board_dispatch.ml's [with_eio] uses. *)
let with_isolated_eio_base_path prefix f =
  let base_dir = temp_base_path prefix in
  Unix.mkdir base_dir 0o700;
  let old_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let old_base_input = Sys.getenv_opt "MASC_BASE_PATH_INPUT" in
  let registry = Fusion_run_registry.create () in
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      restore_env "MASC_BASE_PATH" old_base;
      restore_env "MASC_BASE_PATH_INPUT" old_base_input;
      try remove_tree base_dir with _ -> ())
    (fun () ->
      Unix.putenv "MASC_BASE_PATH" base_dir;
      Unix.putenv "MASC_BASE_PATH_INPUT" base_dir;
      Board_dispatch.reset_for_test ();
      Board.reset_global_for_test ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw -> f env sw base_dir registry)
;;

let with_isolated_base_path prefix f =
  with_isolated_eio_base_path prefix (fun _env _sw base_dir registry ->
    f base_dir registry)
;;

let make_meta ?(name = "fusion-keeper") () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ ("name", `String name)
         ; ("trace_id", `String "test-trace-fusion")
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)
;;

let fusion_payload
      ?(run_id = "fus-1")
      ?(resolved_answer = "use approach B because it is reversible")
      ?terminal
      ?(board_post_id = "post-77")
      ()
  : Keeper_event_queue.fusion_completion
  =
  let terminal =
    Option.value terminal ~default:(Keeper_event_queue.Fusion_succeeded resolved_answer)
  in
  { run_id
  ; terminal
  ; board_post_id
  ; channel = Keeper_continuation_channel.unrouted "test fixture"
  }
;;

let fusion_stimulus ?run_id ?terminal ?resolved_answer ?board_post_id () : Keeper_event_queue.stimulus =
  { post_id = "ignored-by-fusion-arm"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1000.0
  ; payload =
      Keeper_event_queue.Fusion_completed
        (fusion_payload ?run_id ?terminal ?resolved_answer ?board_post_id ())
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
    ; max_output_tokens = None
    ; timeout_s = None
    }
  in
  let preset : Fusion_policy.preset =
    { name = "unit"
    ; panels = [ panel_group ]
    ; judge = "judge.model"
    ; judge_system_prompt = "judge system prompt"
    ; judge_max_output_tokens = None
    ; judge_timeout_s = None
    ; judges = []
    ; min_answered = Fusion_policy.default_min_answered
    }
  in
  { enabled = true
  ; default_preset = preset.name
  ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
  ; presets = [ validated_preset preset ]
  }
;;

let scheduled_wake
      ?(occurrence_id = "schedule-occurrence:test")
      ?(schedule_instance_id = "instance-sched-1")
      ?(schedule_id = "sched-1")
      ?(due_at = 3000.0)
      ?(payload_digest = "digest-1")
      ?(title = Some "Scheduled lane wake")
      ?(message = "SCHEDULE-ANSWER-TOKEN")
      ()
  : Keeper_event_queue.scheduled_wake
  =
  { occurrence_id
  ; schedule_instance_id
  ; schedule_id
  ; due_at
  ; payload_digest
  ; title
  ; message
  ; result_delivery = None
  }
;;

let schedule_stimulus ?schedule_id ?due_at ?payload_digest ?title ?message ()
  : Keeper_event_queue.stimulus
  =
  let wake = scheduled_wake ?schedule_id ?due_at ?payload_digest ?title ?message () in
  { post_id = "schedule-occurrence:test"
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
  check string "post_id is canonical Fusion identity" "fusion-run:fus-1" ev.post_id;
  check bool "preview carries the resolved answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview);
  check string "author remains context" meta.name ev.author;
  check bool "post kind remains context" true
    (ev.post_kind = Board.System_post);
  (* the stimulus path yields Some (not None like Bootstrap) *)
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (fusion_stimulus ~resolved_answer:"ANSWER-TOKEN-xyz" ())
  with
  | Ok (Some (ev : Keeper_world_observation.pending_board_event)) ->
    check bool "stimulus path preview carries the answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview)
  | Ok None -> fail "Fusion_completed stimulus must produce Some pending_board_event, not None"
  | Error unavailable ->
    fail
      ("Fusion_completed stimulus must not hit a board read: "
       ^ Keeper_world_observation_board_signal.unavailable_to_string unavailable)
;;

let test_fusion_cancellation_is_typed_and_actionable () =
  let meta = make_meta () in
  let stimulus =
    fusion_stimulus ~run_id:"fus-cancelled"
      ~terminal:Keeper_event_queue.Fusion_cancelled ()
  in
  let decoded =
    Keeper_event_queue.stimulus_to_yojson stimulus
    |> Keeper_event_queue.stimulus_of_yojson
  in
  (match decoded with
   | Ok
       { payload =
           Keeper_event_queue.Fusion_completed
             { terminal = Keeper_event_queue.Fusion_cancelled; _ }
       ; _
       } -> ()
   | Ok _ -> fail "fusion cancellation codec lost its typed terminal"
   | Error detail -> fail ("fusion cancellation codec failed: " ^ detail));
  match Keeper_world_observation.pending_board_event_of_stimulus ~meta stimulus with
  | Ok (Some event) ->
    check bool "cancellation is explicit in title" true
      (contains ~needle:"cancelled" event.title);
    check bool "cancellation is actionable" true
      (contains ~needle:"structurally cancelled" event.preview)
  | Ok None -> fail "Fusion_cancelled terminal must remain actionable"
  | Error unavailable ->
    fail
      ("Fusion_cancelled terminal must not read Board: "
       ^ Keeper_world_observation_board_signal.unavailable_to_string unavailable)
;;

let test_fusion_missing_terminal_is_rejected () =
  let missing_terminal =
    fusion_stimulus ~run_id:"fus-missing-terminal"
      ~terminal:(Keeper_event_queue.Fusion_succeeded "unused") ()
    |> Keeper_event_queue.stimulus_to_yojson
    |> function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if not (String.equal key "payload")
              then key, value
              else (
                match value with
                | `Assoc payload_fields ->
                  ( key
                  , `Assoc
                      (List.filter
                         (fun (name, _) -> not (String.equal name "terminal"))
                         payload_fields) )
                | _ -> fail "stimulus payload must be an object"))
           fields)
    | _ -> fail "stimulus json must be an object"
  in
  match Keeper_event_queue.stimulus_of_yojson missing_terminal with
  | Error _ -> ()
  | Ok _ -> fail "fusion completion without terminal decoded"
;;

let test_scheduled_wake_is_actionable () =
  let meta = make_meta ~name:"schedule-keeper" () in
  let wake = scheduled_wake ~message:"SCHEDULE-ANSWER-TOKEN" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_scheduled_wake
      ~meta
      ~post_id:"schedule-occurrence:actionable"
      ~arrived_at:3000.0
      wake
  in
  check string "post_id preserves occurrence" "schedule-occurrence:actionable" ev.post_id;
  check bool "preview carries schedule message" true
    (contains ~needle:"SCHEDULE-ANSWER-TOKEN" ev.preview);
  check string "schedule actor remains context" "scheduled_automation" ev.author;
  check bool "post kind remains context" true
    (ev.post_kind = Board.System_post);
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta
      (schedule_stimulus ~message:"SCHEDULE-ANSWER-TOKEN" ())
  with
  | Ok (Some (ev : Keeper_world_observation.pending_board_event)) ->
    check bool "stimulus path preview carries the schedule message" true
      (contains ~needle:"SCHEDULE-ANSWER-TOKEN" ev.preview)
  | Ok None -> fail "Schedule_due stimulus must produce Some pending_board_event, not None"
  | Error unavailable ->
    fail
      ("Schedule_due stimulus must not hit a board read: "
       ^ Keeper_world_observation_board_signal.unavailable_to_string unavailable)
;;

(* (3) Board availability never changes the durable completion identity. *)
let test_missing_board_post_id_fallback () =
  let meta = make_meta () in
  let fc = fusion_payload ~run_id:"fus-9" ~board_post_id:"" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion ~meta ~arrived_at:1.0 fc
  in
  check string "synthetic fallback post id" "fusion-run:fus-9" ev.post_id
;;

let discord_channel =
  Keeper_continuation_channel.discord
    ~guild_id:(Some "g-1")
    ~channel_id:"chan-9"
    ~parent_channel_id:None
    ~thread_id:None
    ~user_id:"user-3"
    ()
  |> Result.get_ok
;;

let test_emit_success_projects_board_chat_and_registry () =
  with_isolated_base_path "fusion-success-sink" (fun base_dir registry ->
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
    let tool_trace = Fusion_types.empty_tool_trace in
    Fusion_run_registry.register_running registry ~run_id ~keeper ~preset:"unit-test" ~topology:Fusion_types.Simple
      ~started_at:2.0;
    let result =
      Fusion_sink.emit ~registry ~base_dir ~keeper ~run_id ~channel:discord_channel
        ~question ~panel ~judge:(Ok synthesis) ~judges ~judge_usage ~tool_trace:(Some tool_trace)
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
    check bool "meta.source is not duplicated" false (List.mem_assoc "source" meta);
    check bool "meta.run_id is not duplicated" false (List.mem_assoc "run_id" meta);
    check string "meta.question" question (string_field "board.meta" meta "question");
    check (float 0.000001) "meta.started_at" 2.0
      (number_field "board.meta" meta "started_at");
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
    let tool_trace_meta =
      assoc_fields "board.meta.tool_trace" (field "board.meta" meta "tool_trace")
    in
    check string "tool trace coverage is explicit" "complete"
      (string_field "board.meta.tool_trace" tool_trace_meta "status");
    check int "complete empty trace has no events" 0
      (list_field "board.meta.tool_trace" tool_trace_meta "events" |> List.length);
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
    check bool "dashboard meta has no duplicate source" false
      (List.mem_assoc "source" dashboard_meta);
    check bool "dashboard meta has no duplicate run id" false
      (List.mem_assoc "run_id" dashboard_meta);
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
    let replay =
      Fusion_sink.emit ~registry ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~question ~panel ~judge:(Ok synthesis) ~judges
        ~judge_usage ~tool_trace:(Some tool_trace)
    in
    check bool "same completion replay succeeds" true (Result.is_ok replay);
    let posts_for_run =
      Board.list_posts (Board.global ()) ()
      |> List.filter (fun (candidate : Board.post) ->
        match candidate.origin with
        | Some { fusion_run_id = Some candidate_run_id; _ } ->
          String.equal candidate_run_id run_id
        | Some { fusion_run_id = None; _ } | None -> false)
    in
    check int "same completion creates one Board post" 1
      (List.length posts_for_run);
    let replay_messages =
      Keeper_chat_store.load ~base_dir ~keeper_name:keeper
      |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
        contains ~needle:resolved_answer message.content)
    in
    check int "same completion appends one chat row" 1
      (List.length replay_messages);
    check int "same completion queues one durable wake" 1
      (Keeper_event_queue.length
         (Keeper_event_queue_persistence.load
            ~base_path:base_dir
            ~keeper_name:keeper));
    let conflicting_replay =
      Fusion_sink.emit ~registry ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~question:(question ^ " changed") ~panel
        ~judge:(Ok synthesis) ~judges ~judge_usage ~tool_trace:(Some tool_trace)
    in
    check bool "changed completion replay is rejected" true
      (Result.is_error conflicting_replay);
    check int "conflicting replay keeps one Board post" 1
      (Board.list_posts (Board.global ()) ()
       |> List.filter (fun (candidate : Board.post) ->
         match candidate.origin with
         | Some { fusion_run_id = Some candidate_run_id; _ } ->
           String.equal candidate_run_id run_id
         | Some { fusion_run_id = None; _ } | None -> false)
       |> List.length);
    check int "conflicting replay keeps one chat row" 1
      (Keeper_chat_store.load ~base_dir ~keeper_name:keeper
       |> List.filter (fun (message : Keeper_chat_store.chat_message) ->
         contains ~needle:resolved_answer message.content)
       |> List.length);
    check int "conflicting replay keeps one durable wake" 1
      (Keeper_event_queue.length
         (Keeper_event_queue_persistence.load
            ~base_path:base_dir
            ~keeper_name:keeper));
    match Fusion_run_registry.get registry ~run_id with
    | Some
        { Fusion_run_registry.status =
            Fusion_run_registry.Completed
              (Fusion_run_registry.Succeeded_with_summary { decision; summary })
        ; _
        } ->
      check string "registry decision preview" ("answer — " ^ resolved_answer)
        decision;
      check string "registry resolved-answer preview" resolved_answer summary
    | Some
        { Fusion_run_registry.status =
            Fusion_run_registry.Completed Fusion_run_registry.Succeeded
        ; _
        } -> fail "current sink success must publish its semantic summary"
    | Some
        { Fusion_run_registry.status =
            Fusion_run_registry.Completed (Fusion_run_registry.Failed _)
        ; _
        } ->
      fail "fusion run should complete successfully"
    | Some { Fusion_run_registry.status = Running; _ } ->
      fail "fusion run should not remain running"
    | None -> fail "fusion run should remain visible")
;;

(* 취소가 실제로 [Fusion_cancelled] 로 키퍼에게 도달하는지 — 이 파일의 기존
   cancellation 테스트는 stimulus 를 손으로 만들어 코덱과 렌더러만 확인했고, 그래서
   "아무도 그 terminal 을 생산하지 않는다" 를 통과시켰다. 실제로 오랫동안 생산자가
   0 이었고 취소된 run 은 전부 [Fusion_failed] 로 도착했다. 이 테스트는 sink 의 실제
   실패 투영 경로를 태워 durable 큐에 들어간 terminal 을 읽는다. *)
let test_cancelled_delivery_reaches_the_keeper_as_cancelled () =
  with_isolated_base_path "fusion-cancel" (fun base_dir registry ->
    let keeper = Printf.sprintf "fusion-cancel-%d" (Random.bits ()) in
    let run_id = Printf.sprintf "fus-cancel-%d" (Random.bits ()) in
    Fusion_run_registry.register_running registry ~run_id ~keeper ~preset:"trio"
      ~topology:Fusion_types.Simple ~started_at:1.0;
    let result =
      Fusion_sink.emit_failure ~registry ~base_dir ~keeper ~run_id
        ~channel:discord_channel
        ~failure:
          (Fusion_sink.Cancelled { reason = "operator stop"; cancelled_by = "vincent" })
    in
    check bool "cancellation projects" true (Result.is_ok result);
    (match
       Keeper_event_queue_persistence.load ~base_path:base_dir ~keeper_name:keeper
       |> Keeper_event_queue.dequeue
     with
     | Some ({ payload = Keeper_event_queue.Fusion_completed fc; _ }, _) ->
       (match fc.terminal with
        | Keeper_event_queue.Fusion_cancelled -> ()
        | Keeper_event_queue.Fusion_failed _ ->
          fail "a cancelled run must not arrive as a judge failure"
        | Keeper_event_queue.Fusion_succeeded _ -> fail "cancellation arrived as success")
     | Some _ -> fail "unexpected durable stimulus kind"
     | None -> fail "cancellation must be durably queued");
    (* registry wire 는 계속 문자열 code 를 싣는다(대시보드가 읽는다) — 다만 그 값이
       typed 실패에서 파생된다. *)
    match Fusion_run_registry.get registry ~run_id with
    | Some { status = Fusion_run_registry.Completed (Fusion_run_registry.Failed { code; _ }); _ }
      -> check string "registry code derives from the typed failure" "cancelled" code
    | _ -> fail "registry must record the run as failed with its code")
;;

(* 대조군: 심판 실패는 여전히 [Fusion_failed] 로 간다. 이게 없으면 위 테스트는
   "모든 실패를 cancelled 로 보내도" 통과한다. *)
let test_judge_failure_still_reaches_the_keeper_as_failed () =
  with_isolated_base_path "fusion-failed" (fun base_dir registry ->
    let keeper = Printf.sprintf "fusion-failed-%d" (Random.bits ()) in
    let run_id = Printf.sprintf "fus-failed-%d" (Random.bits ()) in
    Fusion_run_registry.register_running registry ~run_id ~keeper ~preset:"trio"
      ~topology:Fusion_types.Simple ~started_at:1.0;
    let result =
      Fusion_sink.emit_failure ~registry ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~failure:(Fusion_sink.Computation_failed "boom")
    in
    check bool "failure projects" true (Result.is_ok result);
    match
      Keeper_event_queue_persistence.load ~base_path:base_dir ~keeper_name:keeper
      |> Keeper_event_queue.dequeue
    with
    | Some ({ payload = Keeper_event_queue.Fusion_completed fc; _ }, _) ->
      (match fc.terminal with
       | Keeper_event_queue.Fusion_failed _ -> ()
       | Keeper_event_queue.Fusion_cancelled ->
         fail "a computation failure must not arrive as a cancellation"
       | Keeper_event_queue.Fusion_succeeded _ -> fail "failure arrived as success")
    | Some _ -> fail "unexpected durable stimulus kind"
    | None -> fail "failure must be durably queued")
;;

let test_wake_durable_commit_carries_channel () =
  with_isolated_base_path "fusion-wake-durable" (fun base_dir _registry ->
    let keeper = Printf.sprintf "fusion-wake-%d" (Random.bits ()) in
    let run_id = Printf.sprintf "fus-wake-%d" (Random.bits ()) in
    let result =
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
        ~channel:discord_channel
        ~terminal:(Keeper_event_queue.Fusion_succeeded "WAKE-DURABLE-ANSWER")
        ~board_post_id:"post-wake-1"
    in
    check bool "wake commits durably" true (Result.is_ok result);
    (match
       Keeper_event_queue_persistence.load ~base_path:base_dir ~keeper_name:keeper
       |> Keeper_event_queue.dequeue
     with
     | Some ({ payload = Keeper_event_queue.Fusion_completed fc; _ }, _) ->
       check string "durable completion run id" run_id fc.run_id;
       (match fc.channel with
        | Keeper_continuation_channel.Discord { channel_id = "chan-9"; _ } -> ()
        | other ->
          fail
            (Printf.sprintf "durable channel must be the originating route, got %s"
               (Keeper_continuation_channel.describe other)))
     | Some _ -> fail "unexpected durable stimulus kind"
     | None -> fail "completion stimulus must be durably persisted with its channel");
    let replay =
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "WAKE-DURABLE-ANSWER")
        ~board_post_id:"post-wake-1"
    in
    check bool "exact-recipient replay accepts the committed recipient" true
      (Result.is_ok replay);
    match
      Keeper_event_queue_persistence.load ~base_path:base_dir ~keeper_name:keeper
      |> Keeper_event_queue.dequeue
    with
    | Some
        ( { payload = Keeper_event_queue.Fusion_completed fc; _ }
        , remaining ) ->
      check int "exact-recipient replay keeps one durable completion" 0
        (Keeper_event_queue.length remaining);
      (match fc.channel with
       | Keeper_continuation_channel.Discord { channel_id = "chan-9"; _ } -> ()
       | other ->
         fail
           (Printf.sprintf
              "replay must preserve the first committed recipient, got %s"
              (Keeper_continuation_channel.describe other)))
    | Some _ -> fail "unexpected durable stimulus kind after replay"
    | None -> fail "durable completion disappeared after replay")
;;

let test_wake_fail_closed_rejects_conflicting_delivery () =
  with_isolated_base_path "fusion-wake-failclosed" (fun base_dir _registry ->
    let keeper = Printf.sprintf "fusion-wake-fc-%d" (Random.bits ()) in
    let run_id = Printf.sprintf "fus-wake-fc-%d" (Random.bits ()) in
    let board_post_id = "post-wake-fc-1" in
    let conflicting_payload =
      fusion_payload ~run_id ~board_post_id
        ~resolved_answer:"CONFLICTING-PRIOR-ANSWER" ()
    in
    let conflicting : Keeper_event_queue.stimulus =
      { post_id = Keeper_event_queue.fusion_completion_post_id conflicting_payload
      ; urgency = Keeper_event_queue.Normal
      ; arrived_at = 1.0
      ; payload = Keeper_event_queue.Fusion_completed conflicting_payload
      }
    in
    (match
       Keeper_registry_event_queue.enqueue_durable_result ~base_path:base_dir keeper conflicting
     with
     | Ok () -> ()
     | Error e -> fail (Printf.sprintf "seeding the conflicting durable row should commit: %s" e));
    let result =
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "REAL-ANSWER") ~board_post_id
    in
    check bool "conflicting durable commit fails the wake" true (Result.is_error result))
;;

(* New-architecture successor of the deleted Fusion_wake_route isolation
   guard: recipient identity is carried by the keeper-scoped durable queue and
   the explicit obligation channel, so two Keepers sharing a [run_id] keep
   isolated completions with their own channels. *)
let test_wake_isolates_keeper_run_identity () =
  with_isolated_base_path "fusion-wake-isolation" (fun base_dir _registry ->
    let run_id = Printf.sprintf "fus-iso-%d" (Random.bits ()) in
    let keeper_a = Printf.sprintf "fusion-iso-a-%d" (Random.bits ()) in
    let keeper_b = Printf.sprintf "fusion-iso-b-%d" (Random.bits ()) in
    let channel_b =
      Keeper_continuation_channel.discord
        ~guild_id:(Some "g-2")
        ~channel_id:"chan-b"
        ~parent_channel_id:None
        ~thread_id:None
        ~user_id:"user-7"
        ()
      |> Result.get_ok
    in
    (match
       Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper:keeper_a
         ~run_id ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "ANSWER-A") ~board_post_id:"post-iso-a"
     with
     | Ok () -> ()
     | Error e -> fail (Printf.sprintf "keeper-a wake must commit: %s" e));
    (match
       Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper:keeper_b
         ~run_id ~channel:channel_b ~terminal:(Keeper_event_queue.Fusion_succeeded "ANSWER-B") ~board_post_id:"post-iso-b"
     with
     | Ok () -> ()
     | Error e -> fail (Printf.sprintf "keeper-b wake must commit: %s" e));
    let completion_of keeper_name =
      match
        Keeper_event_queue_persistence.load ~base_path:base_dir ~keeper_name
        |> Keeper_event_queue.dequeue
      with
      | Some ({ payload = Keeper_event_queue.Fusion_completed fc; _ }, rest) ->
        check int "one durable completion per keeper" 0
          (Keeper_event_queue.length rest);
        fc
      | Some _ -> fail "unexpected durable stimulus kind"
      | None -> fail "completion stimulus must be durably persisted"
    in
    let fc_a = completion_of keeper_a in
    let fc_b = completion_of keeper_b in
    check string "keeper-a run id" run_id fc_a.run_id;
    check string "keeper-b run id" run_id fc_b.run_id;
    (match fc_a.channel with
     | Keeper_continuation_channel.Discord { channel_id = "chan-9"; _ } -> ()
     | other ->
       fail
         (Printf.sprintf "keeper-a channel crossed keepers: %s"
            (Keeper_continuation_channel.describe other)));
    match fc_b.channel with
    | Keeper_continuation_channel.Discord { channel_id = "chan-b"; _ } -> ()
    | other ->
      fail
        (Printf.sprintf "keeper-b channel crossed keepers: %s"
           (Keeper_continuation_channel.describe other)))
;;

(* New-architecture successor of the deleted exact-owner guard: no in-memory
   lane capture exists anymore, so a stale lane handle can never be signaled.
   The durable commit is lane-independent — it must succeed and keep the
   obligation-carried channel even when the live lane was replaced.  The wake
   hint itself is name-scoped by design: the durable queue belongs to the
   Keeper name, so the currently registered lane legitimately owns pending
   completions of that Keeper. *)
let test_completion_wake_commits_durably_across_lane_replacement () =
  with_isolated_base_path "fusion-wake-lane-replacement" (fun base_dir _registry ->
    Keeper_registry.For_testing.clear ();
    Fun.protect
      ~finally:Keeper_registry.For_testing.clear
      (fun () ->
         let keeper = Printf.sprintf "fusion-replaced-%d" (Random.bits ()) in
         let run_id = Printf.sprintf "fus-replaced-%d" (Random.bits ()) in
         let meta = make_meta ~name:keeper () in
         let captured =
           Keeper_registry.For_testing.register ~base_path:base_dir keeper meta
         in
         Atomic.set captured.fiber_wakeup false;
         let _replacement =
           Keeper_registry.For_testing.register ~base_path:base_dir keeper meta
         in
         let result =
           Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
             ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "REPLACED-LANE-ANSWER") ~board_post_id:"post-replaced"
         in
         check bool "completion commits despite replaced live lane" true
           (Result.is_ok result);
         check bool "stale lane handle is never signaled" false
           (Atomic.get captured.fiber_wakeup);
         match
           Keeper_event_queue_persistence.load ~base_path:base_dir
             ~keeper_name:keeper
           |> Keeper_event_queue.dequeue
         with
         | Some ({ payload = Keeper_event_queue.Fusion_completed fc; _ }, _) ->
           check string "durable completion run id" run_id fc.run_id;
           (match fc.channel with
            | Keeper_continuation_channel.Discord { channel_id = "chan-9"; _ } ->
              ()
            | other ->
              fail
                (Printf.sprintf "durable channel must be the obligation channel, got %s"
                   (Keeper_continuation_channel.describe other)))
         | Some _ -> fail "unexpected durable stimulus kind"
         | None -> fail "completion stimulus must persist across lane replacement"))
;;

(* New-architecture successor of the Board-recovery identity guard: the Board
   projection is fail-closed via [create_post_once_by_fusion_run_id], so a
   replay always observes the same canonical [board_post_id] and is idempotent;
   a replay carrying a *different* Board identity for the same run is an
   identity conflict that fails closed and leaves the committed row intact. *)
let test_wake_board_recovery_keeps_canonical_identity () =
  with_isolated_base_path "fusion-wake-board-recovery" (fun base_dir _registry ->
    let keeper = Printf.sprintf "fusion-board-recovery-%d" (Random.bits ()) in
    let run_id = Printf.sprintf "fus-board-recovery-%d" (Random.bits ()) in
    let first =
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "RECOVERED-ANSWER")
        ~board_post_id:"post-canonical"
    in
    check bool "completion commits with Board evidence" true (Result.is_ok first);
    let replay =
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "RECOVERED-ANSWER")
        ~board_post_id:"post-canonical"
    in
    check bool "canonical replay is idempotent" true (Result.is_ok replay);
    let conflicting =
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id
        ~channel:discord_channel ~terminal:(Keeper_event_queue.Fusion_succeeded "RECOVERED-ANSWER")
        ~board_post_id:"post-divergent"
    in
    check bool "divergent Board identity fails closed" true
      (Result.is_error conflicting);
    match
      Keeper_event_queue_persistence.load ~base_path:base_dir ~keeper_name:keeper
      |> Keeper_event_queue.to_list
    with
    | [ { post_id; payload = Keeper_event_queue.Fusion_completed completion; _ } ] ->
      check string "canonical durable identity" ("fusion-run:" ^ run_id) post_id;
      check string "first committed Board projection remains authoritative"
        "post-canonical" completion.board_post_id;
      (match completion.channel with
       | Keeper_continuation_channel.Discord { channel_id = "chan-9"; _ } -> ()
       | other ->
         fail
           (Printf.sprintf "first committed channel changed: %s"
              (Keeper_continuation_channel.describe other)))
    | _ -> fail "Board identity replay created more than one durable completion")
;;

let test_completion_stimulus_persists_without_live_registry () =
  with_isolated_base_path "fusion-wake-offline" (fun base_dir _registry ->
    let keeper = Printf.sprintf "fusion-offline-%d" (Random.bits ()) in
    let stimulus = fusion_stimulus ~run_id:"fus-offline" () in
    Keeper_keepalive_signal.wakeup_keeper
      ~base_path:base_dir
      ~stimulus
      keeper;
    match
      Keeper_event_queue_persistence.load
        ~base_path:base_dir
        ~keeper_name:keeper
      |> Keeper_event_queue.dequeue
    with
    | Some ({ payload = Keeper_event_queue.Fusion_completed completion; _ }, rest) ->
      check string "durable completion run" "fus-offline" completion.run_id;
      check int "only one durable stimulus" 0 (Keeper_event_queue.length rest)
    | Some _ -> fail "unexpected durable stimulus kind"
    | None -> fail "completion stimulus must persist without a live registry entry")
;;

let test_tool_handle_async_success_projects_running_then_completed () =
  with_isolated_eio_base_path "fusion-tool-async-success"
    (fun env sw base_dir registry ->
    let keeper = "fusion-tool-keeper" in
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
    let computed_promise, resolve_computed = Eio.Promise.create () in
    let compute ~sw:_ ~net:_ ~policy:_ ~topology:_ ~request:_ () =
      Eio.Promise.await release_promise;
      let evidence : Fusion_types.deliberation_evidence =
        { question
        ; panel
        ; judge = Ok synthesis
        ; judges
        ; judge_usage
        ; tool_trace = None
        }
      in
      Eio.Promise.resolve resolve_computed ();
      Fusion_orchestrator.Computed evidence
    in
    let response =
      Fusion_tool.For_test.handle_with_compute ~compute ~sw
        ~net:(Eio.Stdenv.net env) ~base_dir ~keeper ~now_unix:4.0
        ~policy:(fusion_tool_policy ()) ~registry
        ~args:(`Assoc [ ("prompt", `String question) ])
        ()
    in
    let response_fields =
      Yojson.Safe.from_string response |> assoc_fields "fusion_tool.response"
    in
    check bool "handle response ok" true
      (bool_field "fusion_tool.response" response_fields "ok");
    check string "handle response status" "fusion_started"
      (string_field "fusion_tool.response" response_fields "status");
    let run_id = string_field "fusion_tool.response" response_fields "run_id" in
    check bool "delivery tells keeper not to poll" true
      (contains
         ~needle:"No need to poll masc_fusion_status"
         (string_field "fusion_tool.response" response_fields "delivery"));
    (match Fusion_run_registry.get registry ~run_id with
     | Some { keeper = observed_keeper; preset; status = Fusion_run_registry.Running; _ } ->
       check string "running keeper" keeper observed_keeper;
       check string "running preset" "unit" preset
     | Some { Fusion_run_registry.status = Completed _; _ } ->
       fail "fusion run should still be Running before the background runner is released"
     | None -> fail "fusion run should be registered as Running before completion");
    Eio.Promise.resolve resolve_release ();
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 (fun () ->
      Eio.Promise.await computed_promise;
      let rec await_projection () =
        match Fusion_run_registry.get registry ~run_id with
        | Some { Fusion_run_registry.status = Completed _; _ } -> ()
        | Some { Fusion_run_registry.status = Running; _ } | None ->
          Eio.Fiber.yield ();
          await_projection ()
      in
      await_projection ());
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
    match Fusion_run_registry.get registry ~run_id with
    | Some
        { Fusion_run_registry.status =
            Fusion_run_registry.Completed
              (Fusion_run_registry.Succeeded_with_summary { decision; summary })
        ; _
        } ->
      check string "async registry decision preview"
        ("answer — " ^ resolved_answer) decision;
      check string "async registry resolved-answer preview" resolved_answer summary
    | Some
        { Fusion_run_registry.status =
            Fusion_run_registry.Completed Fusion_run_registry.Succeeded
        ; _
        } -> fail "current async sink success must publish its semantic summary"
    | Some
        { Fusion_run_registry.status =
            Fusion_run_registry.Completed (Fusion_run_registry.Failed _)
        ; _
        } ->
      fail "fusion run should complete successfully"
    | Some { Fusion_run_registry.status = Running; _ } ->
      fail "fusion run should not remain Running after background success"
    | None -> fail "fusion run should remain visible after background success")
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
            "fusion cancellation has a typed actionable terminal"
            `Quick
            test_fusion_cancellation_is_typed_and_actionable
        ; test_case
            "fusion completion without terminal is rejected"
            `Quick
            test_fusion_missing_terminal_is_rejected
        ; test_case
            "missing board_post_id falls back to fusion-run id"
            `Quick
            test_missing_board_post_id_fallback
        ; test_case
            "emit success projects board, chat block, and registry"
            `Quick
            test_emit_success_projects_board_chat_and_registry
        ; test_case
            "wake durably commits the explicit continuation channel"
            `Quick
            test_wake_durable_commit_carries_channel
        ; test_case
            "wake fail-closed: conflicting durable delivery is rejected"
            `Quick
            test_wake_fail_closed_rejects_conflicting_delivery
        ; test_case
            "wake isolates (keeper, run_id) recipient identity"
            `Quick
            test_wake_isolates_keeper_run_identity
        ; test_case
            "completion wake commits durably across lane replacement"
            `Quick
            test_completion_wake_commits_durably_across_lane_replacement
        ; test_case
            "Board recovery replay keeps canonical wake identity"
            `Quick
            test_wake_board_recovery_keeps_canonical_identity
        ; test_case
            "completion stimulus persists without live registry"
            `Quick
            test_completion_stimulus_persists_without_live_registry
        ; test_case
            "tool handle returns Running then async success projects evidence"
            `Quick
            test_tool_handle_async_success_projects_running_then_completed
        ; test_case
            "scheduled wake is actionable (non-empty, carries message)"
            `Quick
            test_scheduled_wake_is_actionable
        ; test_case
            "cancelled delivery reaches the keeper as cancelled"
            `Quick
            test_cancelled_delivery_reaches_the_keeper_as_cancelled
        ; test_case
            "judge failure still reaches the keeper as failed"
            `Quick
            test_judge_failure_still_reaches_the_keeper_as_failed
        ] )
    ]
;;
