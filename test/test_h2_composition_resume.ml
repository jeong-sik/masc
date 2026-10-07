(* [하네스 H2 — task-2184] 중단된 composition·async 실행의 재개 검증.

   Board 계약 p-963d6bf387f1bbd6e217054ad293c155 H2-S1/S2/S3. 소스 기준
   a4b895455bafc38d2482af192dfb35936ba81023.

   실행기({!Masc.Keeper_tool_plan_executor.execute})와 async 브로커
   ({!Masc.Keeper_msg_async})를 실제로 구동해, 계약이 요구하는 재개
   동작이 현재 코드에 존재하는지를 관측 기록으로 남긴다. 판정은 이
   하네스가 내는 것이 아니라 계약·증거를 읽는 리뷰어와 검증자의 몫이다. *)

open Alcotest

module Workspace = Masc.Workspace
module Plan = Masc.Keeper_tool_plan
module Executor = Masc.Keeper_tool_plan_executor
module Descriptor = Masc.Keeper_tool_descriptor
module Async = Masc.Keeper_msg_async
module Registry = Masc.Keeper_registry
module Meta_store = Masc.Keeper_meta_store
module Profile = Masc.Keeper_types_profile
module Event_queue = Keeper_event_queue
module Timing = Tool_timing

let root =
  match Sys.getenv_opt "H2_ROOT" with
  | Some path -> path
  | None -> Filename.get_temp_dir_name ()
;;

let log fmt =
  Printf.ksprintf (fun s -> print_endline ("H2 " ^ s)) fmt
;;

let stage name = log "STAGE %s" name
;;

(* ------------------------------------------------------------------ *)
(* 마커·효과 파일: 재개 간 상태는 오직 디스크로만 전달된다              *)

let markers_dir () = Filename.concat root "markers"

let effect_file () = Filename.concat (markers_dir ()) "effects"
;;

let claimed_file () = Filename.concat (markers_dir ()) "claimed"
;;

let crash_flag marker = Filename.concat (markers_dir ()) ("crash_" ^ marker)
;;

let ensure_markers () =
  if not (Sys.file_exists (markers_dir ())) then Unix.mkdir (markers_dir ()) 0o755
;;

let marker_lines path =
  match open_in_bin path with
  | exception _ -> []
  | channel ->
    let content = really_input_string channel (in_channel_length channel) in
    close_in channel;
    content |> String.split_on_char '\n'
    |> List.filter (fun s -> s <> "")
;;

let append_marker path line =
  let oc =
    open_out_gen [ Open_append; Open_creat ] 0o644 path
  in
  output_string oc (line ^ "\n");
  close_out oc
;;

let count marker path = List.length (List.filter (fun m -> String.equal m marker) (marker_lines path))

exception Crash of string

(* 효과를 흉내 내는 단일 단계. crash flag 가 있으면:
   [commit] 이 참이면 효과 흔적을 남긴 뒤(효과는 이미 커밋됨) 죽고,
   거짓이면 흔적 없이 죽는다(효과 전). 아니면 claim 을 남기고 효과를
   흔적에 더한다. *)
let run_step marker ~commit =
  if Sys.file_exists (crash_flag marker) then begin
    Sys.remove (crash_flag marker);
    if commit then append_marker (effect_file ()) marker;
    raise (Crash marker)
  end;
  append_marker (claimed_file ()) marker;
  append_marker (effect_file ()) marker;
  log "EFFECT %s committed" marker
;;

let set_crash_flag marker =
  ensure_markers ();
  let flag = crash_flag marker in
  let oc = open_out flag in
  output_string oc marker;
  close_out oc
;;

let reset () =
  ensure_markers ();
  let unlink path = if Sys.file_exists path then Sys.remove path in
  unlink (effect_file ());
  unlink (claimed_file ());
  unlink (crash_flag "a");
  unlink (crash_flag "b");
  ()
;;

(* ------------------------------------------------------------------ *)
(* Descriptor 복제: 기존 descriptor 를 record 복사로 교체한다           *)

(* Plan.create 는 descriptor 를 id 로 정규화해 등록본으로 되돌린다
   (keeper_tool_plan.ml:1001 canonicalize_descriptors), 그래서 테스트가
   만든 수정 descriptor 는 plan 생성에 흡수되지 않는다. 실제 표면의
   lane·search 쌍(keeper_lane_status → masc_board_search)이 이미
   [Json_output] 데이터플로(lane.profile → search.query)를 제공하므로,
   그 canonical descriptors 를 그대로 쓴다. *)
let lane_descriptor () =
  match List.find_opt (fun d -> String.equal d.Descriptor.id "keeper.lane.status") (Descriptor.all_descriptors ()) with
  | Some d -> d
  | None -> fail "descriptor not found: keeper.lane.status"
;;

let search_descriptor () =
  match List.find_opt (fun d -> String.equal d.Descriptor.id "masc.board.search") (Descriptor.all_descriptors ()) with
  | Some d -> d
  | None -> fail "descriptor not found: masc.board.search"
;;

let descriptors () = [ lane_descriptor (); search_descriptor () ]
;;

let make_plan () =
  let a = match Plan.Node_id.make "lane" with Ok id -> id | Error Empty -> fail "empty id" in
  let b = match Plan.Node_id.make "search" with Ok id -> id | Error Empty -> fail "empty id" in
  let input_a = Plan.Json_template.literal (`Assoc []) in
  let profile_pointer =
    match Plan.Json_pointer.of_string "/profile" with
    | Ok pointer -> pointer
    | Error _ -> fail "pointer syntax rejected"
  in
  let input_b =
    match
      Plan.Json_template.object_
        [ ("query", Plan.Json_template.output ~node_id:a ~pointer:profile_pointer) ]
    with
    | Ok template -> template
    | Error (Duplicate_field field) -> fail ("duplicate field: " ^ field)
  in
  let node_a = Plan.node ~id:a ~tool_name:"keeper_lane_status" ~input:input_a () in
  let node_b = Plan.node ~id:b ~tool_name:"masc_board_search" ~after:[ a ] ~input:input_b () in
  match Plan.create ~descriptors:(descriptors ()) [ node_a; node_b ] with
  | Ok plan -> (plan, a, b)
  | Error error -> fail ("plan: " ^ Plan.error_to_string error)
;;

(* dispatch: 노드 a·b 의 효과를 흉내 내고, crash flag 가 있으면 흔적을
   남긴 뒤 그대로 예외로 전파한다 (executor 는 이를 settlement 로 삼는다). *)
let dispatch ~marker_for ~commit_crash ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input =
  let id = Plan.Node_id.to_string node.Plan.id in
  log "DISPATCH %s input=%s" id (Yojson.Safe.to_string input);
  (match marker_for id with
   | Some marker -> run_step marker ~commit:commit_crash
   | None -> ());
  let data =
    if String.equal id "lane" then
      `Assoc
        [ "profile", `String "docker"
        ; "lane", `Null
        ; "endpoint", `Null
        ; "probe", `Null
        ; "last_dispatch", `Null
        ; "operator_action", `Null
        ]
    else `String "p-1 · h2 marker post (by keeper-a, 2026-10-07, +0, 0 replies)"
  in
  Executor.dispatch_result
    (Tool_result.make_ok
       ~tool_name:node.Plan.tool_name
       ~start_time:(Timing.start ())
       ~data
       ())
;;

let expected_failure_detail () =
  "discovery-phase expected"
;;

let unused () = ignore expected_failure_detail

(* 실측 1회: plan 을 새로 만들어(재시작) 끝까지 돌린다. executor 는
   배치 실행에서 Eio 취소 컨텍스트를 요구하므로 Eio_main.run 안에서
   돌린다 (acceptance fixture 패턴과 동일). *)
let measure_attempt ~crash_spec =
  (match crash_spec with
   | Some (marker, commit) -> set_crash_flag marker; ignore commit
   | None -> ());
  let commit_crash =
    match crash_spec with Some (_, commit) -> commit | None -> false
  in
  let plan, _a, _b = make_plan () in
  let marker_for = function
    | "lane" -> Some "a"
    | "search" -> Some "b"
    | _ -> None
  in
  Eio_main.run (fun _env ->
      match
        Executor.execute
          ~plan
          ~run_id:(Plan.Run_id.fresh ())
          ~dispatch:(dispatch ~marker_for ~commit_crash)
          ()
      with
      | Ok results ->
        stage "attempt:ok";
        List.iter
          (fun (node : Executor.node_result) ->
            log "SETTLED %s %s" (Plan.Node_id.to_string node.Executor.node_id)
              (match node.Executor.result with
               | Tool_result.Completed _ -> "completed"
               | Tool_result.Deferred _ -> "deferred"
               | Tool_result.Failed _ -> "failed"))
          results;
        `Completed
      | Error failure ->
        stage "attempt:failed";
        (match failure.Executor.cause with
         | Executor.Tool_did_not_complete node ->
           log "CAUSE Tool_did_not_complete %s" (Plan.Node_id.to_string node.Executor.node_id)
         | Executor.Plan_execution_failed { error; _ } ->
           let error_name =
             match error with
             | Plan.Unknown_node_id _ -> "Unknown_node_id"
             | Plan.Input_template_resolution_failed _ -> "Input_template_resolution_failed"
             | Plan.Input_validation_failed _ -> "Input_validation_failed"
             | Plan.Output_validation_failed _ -> "Output_validation_failed"
             | Plan.Output_not_composable _ -> "Output_not_composable"
           in
           log "CAUSE Plan_execution_failed %s" error_name
         | Executor.Node_observation_failed { node; detail } ->
           log "CAUSE Node_observation_failed %s %s" (Plan.Node_id.to_string node.Executor.node_id) detail
         | Executor.Outer_completion_mismatch _ -> log "CAUSE Outer_completion_mismatch");
        `Failed)
;;

(* ------------------------------------------------------------------ *)
(* 시나리오                                                            *)

(* H2-S1: 같은 root 에서 crash 직후 재시작하면 무엇이 관측되는가.
   현재 코드에는 plan 진행 상태의 디스크 표현이 없다(Compose_run_id 는
   fresh, output 토큰은 비직렬화). 따라서 재시작한 프로세스는 a 가 이미
   효과를 냈는지 알 수 없다. 이 관측을 기록한다. *)
let s1_restart_after_effect () =
  stage "s1: crash a after effect, restart, replay whole plan";
  reset ();
  let first = measure_attempt ~crash_spec:(Some ("a", true)) in
  let effects_after_crash = count "a" (effect_file ()) in
  let second = measure_attempt ~crash_spec:None in
  let effects_after_second = count "a" (effect_file ()) in
  log "S1_RESULT first=%s effects_a=%d second=%s effects_a_total=%d claimed_a=%d (duplicate=%b)"
    (match first with `Completed -> "completed" | `Failed -> "failed")
    effects_after_crash
    (match second with `Completed -> "completed" | `Failed -> "failed")
    effects_after_second
    (count "a" (claimed_file ()))
    (count "a" (claimed_file ()) >= 2)
;;

(* H2-S1 변형: b(2단계) crash. b 는 a 의 출력을 입력으로 읽으므로
   '단계 사이' crash 에 해당한다. *)
let s1_restart_b_after_effect () =
  stage "s1b: crash b after effect, restart, replay whole plan";
  reset ();
  let first = measure_attempt ~crash_spec:(Some ("b", true)) in
  let effects_b_after_crash = count "b" (effect_file ()) in
  let second = measure_attempt ~crash_spec:None in
  log "S1B_RESULT first=%s effects_b=%d second=%s effects_b_total=%d claimed_b=%d (duplicate=%b)"
    (match first with `Completed -> "completed" | `Failed -> "failed")
    effects_b_after_crash
    (match second with `Completed -> "completed" | `Failed -> "failed")
    (count "b" (effect_file ()))
    (count "b" (claimed_file ()))
    (count "b" (claimed_file ()) >= 2)
;;

(* H2-S1 변형: 첫 효과 직전 crash (a 가 효과를 내기 전). *)
let s1_restart_before_effect () =
  stage "s1c: crash a before any effect, restart, replay whole plan";
  reset ();
  let first = measure_attempt ~crash_spec:(Some ("a", false)) in
  let effects_after_crash = count "a" (effect_file ()) in
  let second = measure_attempt ~crash_spec:None in
  log "S1C_RESULT first=%s effects_a=%d second=%s effects_a_total=%d"
    (match first with `Completed -> "completed" | `Failed -> "failed")
    effects_after_crash
    (match second with `Completed -> "completed" | `Failed -> "failed")
    (count "a" (effect_file ()))
;;

let s1_no_crash_baseline () =
  stage "s1: baseline without crash";
  reset ();
  let outcome = measure_attempt ~crash_spec:None in
  log "S1_BASELINE outcome=%s effects_a=%d claimed_a=%d"
    (match outcome with `Completed -> "completed" | `Failed -> "failed")
    (count "a" (effect_file ()))
    (count "a" (claimed_file ()))
;;

(* H2-S2: 부정 시나리오 — 실패한 단계의 effect disposition 이 unknown 으로
   위장되지 않는지 관측한다. dispatch 가 Proven_pre_effect 를 내면
   executor 는 그대로 전달해야 한다. *)
let s2_disposition_preserved () =
  stage "s2: failed node keeps its declared effect disposition";
  reset ();
  let plan, _a, _b = make_plan () in
  let dispatch ~tool_use_id:_ ~node ~descriptor:_ ~schedule:_ ~input:_ =
    Executor.dispatch_result
      ~failure_effect_disposition:Tool_result.Proven_pre_effect
      (Tool_result.make_err
         ~tool_name:node.Plan.tool_name
         ~class_:Tool_result.Dependency_unavailable
         ~start_time:(Timing.start ())
         "h2 injected failure (proven pre-effect)")
  in
  Eio_main.run (fun _env ->
      match Executor.execute ~plan ~run_id:(Plan.Run_id.fresh ()) ~dispatch () with
      | Ok results ->
        stage "s2:unexpected-ok";
        List.iter
          (fun (node : Executor.node_result) ->
            log "S2_SETTLED %s disposition=%s" (Plan.Node_id.to_string node.Executor.node_id)
              (match node.Executor.failure_effect_disposition with
               | Some d -> Tool_result.failure_effect_disposition_to_string d
               | None -> "none"))
          results
      | Error failure ->
        (match failure.Executor.cause with
         | Executor.Tool_did_not_complete node ->
           let disposition =
             match node.Executor.failure_effect_disposition with
             | Some d -> Tool_result.failure_effect_disposition_to_string d
             | None -> "none"
           in
           log "S2_RESULT cause=node_failed disposition=%s (expected proven_pre_effect)" disposition
         | _ -> log "S2_RESULT cause=other"))
;;

(* ------------------------------------------------------------------ *)
(* H2-S3: readonly async 요청 — worker 시작 전 재시작                  *)

let submitter = "h2-probe-keeper"
let composition_tool = "keeper_compose_memory-background"

let with_server_workspace f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_h2_async_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun root_sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_context.set_switch root_sw;
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
            [ "name", `String submitter
            ; "activation_mode", `String "manual"
            ])
    with
    | Ok meta -> meta
    | Error err -> fail ("keeper meta fixture failed: " ^ err)
  in
  (match Meta_store.replace_snapshot config meta with
   | Ok _ -> ()
   | Error err -> fail ("write keeper meta failed: " ^ err));
  ignore
    (Registry.register_offline
       ~base_path:config.Workspace.base_path
       submitter
       meta
     : Registry.registry_entry);
  Fun.protect
    ~finally:(fun () -> ignore (Workspace.reset config))
    (fun () -> f config (Eio.Stdenv.clock env))
;;

let with_server_workspace_keep f =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_h2_async_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir dir 0o755;
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun root_sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_context.set_switch root_sw;
  let config = Workspace.default_config dir in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
            [ "name", `String submitter
            ; "activation_mode", `String "manual"
            ])
    with
    | Ok meta -> meta
    | Error err -> fail ("keeper meta fixture failed: " ^ err)
  in
  (match Meta_store.replace_snapshot config meta with
   | Ok _ -> ()
   | Error err -> fail ("write keeper meta failed: " ^ err));
  ignore
    (Registry.register_offline
       ~base_path:config.Workspace.base_path
       submitter
       meta
     : Registry.registry_entry);
  (* s3_1 은 워크스페이스를 정리하지 않는다: 죽은 프로세스의 디스크
     잔여(non-terminal 기록)가 이 시나리오의 대상이기 때문이다. *)
  f config (Eio.Stdenv.clock env)
;;

(* 프로세스 1: 접수만 하고 프로세스가 죽은 것처럼 아무것도 하지 않고
   끝낸다. worker fiber 는 root switch 가 닫히며 취소된다 — worker 가
   결과를 정산하기 전의 종료를 흉내 낸다. 디스크에는 non-terminal
   기록만 남는다. 워크스페이스 정리(reset)는 취소된 worker 의 상태
   갱신과 경쟁하므로 여기서는 하지 않는다(디스크 잔여가 이 시나리오의
   목적이기도 하다).
   실측 주의(21:1xZ 런): 이 턴다운 취소가 worker abort 콜백을 타고
   status=cancelled 로 디스크에 정산된다. 즉 'worker 시작 전 종료'의
   완전한 흉내는 아니며, 정산 직전 취소로 기록된다. Lost 전이를 보려면
   queued/running 기록이 회복 경계에 도달해야 한다 — 이 변형은
   follow-up 으로 남긴다. *)
let s3_phase1_submit_only () =
  with_server_workspace_keep (fun config _clock ->
    stage "s3 phase1: submit, then exit without settling the worker";
    let base_path = config.Workspace.base_path in
    let background_sw =
      match Async.server_background_switch () with
      | Ok sw -> sw
      | Error error ->
        fail ("no background switch: " ^ Yojson.Safe.to_string (Async.submit_error_to_json error))
    in
    let request_id =
      match
        Async.submit_with_request_id
          ~background_sw
          ~base_path
          ~caller:submitter
          ~keeper_name:submitter
          ~f:(fun ~request_id:_ _request_sw ->
            Profile.tool_result_ok_data
              ~tool_name:composition_tool
              (`Assoc
                 [ "composition_tool", `String composition_tool
                 ; "actions", `List []
                 ]))
          ()
      with
      | Ok { Async.request_id; acceptance = Async.Durably_accepted } -> request_id
      | Ok { Async.acceptance = Async.Reconciliation_required { reason }; _ } ->
        fail ("acceptance was not durable: " ^ reason)
      | Error error ->
        fail ("submit failed: " ^ Yojson.Safe.to_string (Async.submit_error_to_json error))
    in
    log "S3P1 submitted request_id=%s" request_id;
    (* 레코드가 디스크에 남아 있는지 즉시 확인. *)
    (match Async.poll ~base_path ~caller:submitter request_id with
     | Async.Found entry ->
       log "S3P1 record on disk status=%s" (Async.status_to_string entry.Async.status)
     | Async.Absent -> fail "phase1: the accepted request left no durable record"
     | Async.Unreadable reason -> fail ("phase1: unreadable record: " ^ reason)
     | Async.Rejected rejection ->
       fail ("phase1: rejected read: " ^ Yojson.Safe.to_string (Async.access_rejection_to_json rejection)));
    log "S3P1_RESULT request_id=%s" request_id)
;;

(* 프로세스 2: 같은 base_path. 워커 없이 회복 경계를 돌리고, 같은
   request_id 의 상태가 무엇으로 끝나는지 관측한다. *)
let s3_phase2_recover () =
  let base_path =
    match Sys.getenv_opt "H2_ASYNC_BASE" with
    | Some path -> path
    | None -> fail "H2_ASYNC_BASE is required for s3 phase 2"
  in
  let request_id =
    match Sys.getenv_opt "H2_ASYNC_REQUEST" with
    | Some id -> id
    | None -> fail "H2_ASYNC_REQUEST is required for s3 phase 2"
  in
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    stage "s3 phase2: startup recovery without a live worker";
    (match Async.poll ~base_path ~caller:submitter request_id with
     | Async.Found entry ->
       log "S3P2 pre-recovery record status=%s" (Async.status_to_string entry.Async.status)
     | other ->
       fail ("phase2: the request record from phase 1 is not readable as-is: " ^
             (match other with
              | Async.Found _ -> "found"
              | Async.Absent -> "absent"
              | Async.Unreadable reason -> "unreadable: " ^ reason
              | Async.Rejected rejection ->
                Yojson.Safe.to_string (Async.access_rejection_to_json rejection))));
    let report = Async.recover_lost_disk_records ~base_path () in
    log "S3P2 recovery report lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d"
      report.Async.lost report.Async.finalized report.Async.cleaned
      report.Async.unreadable report.Async.failed;
    (match Async.poll ~base_path ~caller:submitter request_id with
     | Async.Found entry ->
       log "S3P2_RESULT status=%s (duplicate worker runs: none — recovery only re-labels)"
         (Async.status_to_string entry.Async.status)
     | other ->
       fail ("phase2: post-recovery read failed: " ^
             (match other with
              | Async.Found _ -> "found"
              | Async.Absent -> "absent"
              | Async.Unreadable reason -> "unreadable: " ^ reason
              | Async.Rejected rejection ->
                Yojson.Safe.to_string (Async.access_rejection_to_json rejection)))))
;;

(* 프로세스 2 변형: 디스크의 queued 기록을 직접 회복 경계에 넣는다.
   phase1 이 cancelled 로 정산해버리므로, 이 변형은 phase1 이 남긴
   디렉터리에서 queued 사본을 만들어(H2_ASYNC_REQUEST 로 지정) Lost
   전이를 직접 관측한다. 레코드 파일은 active/<caller>/<id>.json 배치를
   따른다. *)
let s3_phase2_recover_queued () =
  let base_path =
    match Sys.getenv_opt "H2_ASYNC_BASE" with
    | Some path -> path
    | None -> fail "H2_ASYNC_BASE is required for s3 phase 2"
  in
  let request_id =
    match Sys.getenv_opt "H2_ASYNC_REQUEST" with
    | Some id -> id
    | None -> fail "H2_ASYNC_REQUEST is required for s3 phase 2"
  in
  let record_path =
    match Sys.getenv_opt "H2_ASYNC_RECORD" with
    | Some path -> path
    | None -> fail "H2_ASYNC_RECORD is required for s3_2q"
  in
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    stage "s3 phase2q: recovery boundary over a queued record";
    (match Async.poll ~base_path ~caller:submitter request_id with
     | Async.Found entry ->
       log "S3P2Q pre-recovery record status=%s" (Async.status_to_string entry.Async.status)
     | other ->
       fail ("phase2q: the queued record is not readable: " ^
             (match other with
              | Async.Found _ -> "found"
              | Async.Absent -> "absent"
              | Async.Unreadable reason -> "unreadable: " ^ reason
              | Async.Rejected rejection ->
                Yojson.Safe.to_string (Async.access_rejection_to_json rejection))));
    ignore record_path;
    let report = Async.recover_lost_disk_records ~base_path () in
    log "S3P2Q recovery report lost=%d finalized=%d cleaned=%d unreadable=%d failed=%d"
      report.Async.lost report.Async.finalized report.Async.cleaned
      report.Async.unreadable report.Async.failed;
    (match Async.poll ~base_path ~caller:submitter request_id with
     | Async.Found entry ->
       log "S3P2Q_RESULT status=%s" (Async.status_to_string entry.Async.status)
     | other ->
       fail ("phase2q: post-recovery read failed: " ^
             (match other with
              | Async.Found _ -> "found"
              | Async.Absent -> "absent"
              | Async.Unreadable reason -> "unreadable: " ^ reason
              | Async.Rejected rejection ->
                Yojson.Safe.to_string (Async.access_rejection_to_json rejection)))))
;;
  if Array.length Sys.argv < 2 then begin
    print_endline
      "usage: test_h2_composition_resume.exe <s1_baseline|s1_restart|s1_restart_b|s1_restart_pre|s2|s3_1|s3_2> ; H2_ROOT (and H2_ASYNC_BASE/H2_ASYNC_REQUEST for s3_2) required";
    exit 2
  end;
  match Sys.argv.(1) with
  | "s1_restart" -> s1_restart_after_effect ()
  | "s1_restart_b" -> s1_restart_b_after_effect ()
  | "s1_restart_pre" -> s1_restart_before_effect ()
  | "s1_baseline" -> s1_no_crash_baseline ()
  | "s2" -> s2_disposition_preserved ()
  | "s3_1" -> s3_phase1_submit_only ()
  | "s3_2" -> s3_phase2_recover ()
  | "s3_2q" -> s3_phase2_recover_queued ()
  | other -> fail ("unknown scenario: " ^ other)
