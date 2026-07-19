(* Fusion — masc_fusion 키퍼 도구 핸들러 로직 (구현).
   계약/문서: fusion_tool.mli, docs/rfc/RFC-0252 §4/§6 *)

let status_json ~ok fields =
  Yojson.Safe.to_string (`Assoc (("ok", `Bool ok) :: fields))

let status_result ~tool_name ~class_ ~ok fields =
  let data = `Assoc (("ok", `Bool ok) :: fields) in
  if ok
  then Tool_result.make_ok ~tool_name ~start_time:0.0 ~data ()
  else
    let message = Yojson.Safe.to_string data in
    Tool_result.make_err ~tool_name ~class_ ~start_time:0.0 ~data message
;;

let append_chat_failure ~base_dir ~keeper ~run_id ~failure_code content =
  (* 실패 알림도 성공 결론(fusion_sink.emit)과 동일하게 키퍼 *메인* conversation에
     남긴다(conversation_id 생략). recent_direct_conversation observation 필터는
     conversation_id를 보지 않고 role/kind만 보므로
     (keeper_world_observation_message_scope.ml:recent_direct_conversation_of_messages),
     별도 "fusion/<run_id>" 스레드는 메인 오염을 막지 못하면서 한 run의 성공/실패만
     다른 lane으로 흩어지는 split-brain을 만든다. denied/sink_failed/aborted는 키퍼가
     다음 턴에 인지해야 할 운영 실패이므로 메인 lane이 옳다(run_id는 content에 포함). *)
  (* RFC-0266 §7: 종료 상태(Completed{ok=false})를 *suspending append 이전* 에 확정한다.
     [mark_completed]는 순수 in-memory CAS(suspension 없음)라 취소 컨텍스트에서도 안전한
     반면, 아래 append는 Eio 파일 I/O라 셧다운/형제 fiber Switch.fail 시 Cancelled를
     재전파(아래 with 분기)하며 함수를 빠져나간다. finalize를 append *뒤* 에 두면 그 경로에서
     run이 registry([global], 서버 수명)에 "running"으로 남는다(prune는 Running을 evict 안 함
     — fusion_run_registry.ml). 순수 프로세스 셧다운이면 global이 프로세스와 함께 소멸하므로,
     *영구* 잔존은 프로세스가 살아남는 형제 Switch.fail/sub-switch 취소에 한한다. #21784는
     orchestrator-level Cancelled(handle fork match)
     만 막았고 이 내부 append window는 못 막았다. Denied/Sink_failed/aborted 종료 분기가 모두
     이 함수를 경유하므로 같은 누수의 형제 경로다. *)
  Fusion_run_registry.mark_completed (Fusion_run_registry.global ()) ~run_id
    ~failure:content ~failure_code ~ok:false ();
  (try
     Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper ~content ();
     Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
       ~content
       ()
   with
   | Eio.Cancel.Cancelled _ as exn ->
     let bt = Printexc.get_raw_backtrace () in
     Printexc.raise_with_backtrace exn bt
   | exn ->
     Log.Keeper.warn ~keeper_name:keeper
       "fusion run %s failed to append failure message: %s" run_id
       (Printexc.to_string exn));
  (* RFC-0266: 실패도 호출 키퍼를 ok=false로 깨워 "결과 안 옴" 폴링 대신 능동 통지한다
     (성공 경로의 fusion_sink.emit wake와 대칭). content가 실패 사유 라벨이 된다.
     broadcast/wake도 suspending I/O다. append가 Cancelled를 재전파하면 여기 도달하지 못하나
     (generic append 실패는 warn 후 계속 진행해 도달한다), registry는 위에서 이미 갱신됐으므로
     어느 경우든 가시성은 보존된다. *)
  Fusion_sink.broadcast_run_status ~registry:(Fusion_run_registry.global ()) ~run_id;
  (* The failure conclusion is already durable on the chat lane above, and the
     wake ERROR-logs its own durable-commit failure, so a degraded completion
     wake here is degraded reply-channel routing — not a change to the
     failure-notification contract. Match explicitly rather than swallow. *)
  match
    Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok:false
      ~resolved_answer:content ~board_post_id:""
  with
  | Ok () -> ()
  | Error reason ->
    Log.Keeper.warn
      ~keeper_name:keeper
      "fusion run %s completion wake was not durably queued: %s"
      run_id
      reason

type computation =
  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> policy:Fusion_policy.t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> unit
  -> Fusion_orchestrator.compute_outcome

type projection =
  base_dir:string
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> Fusion_types.deliberation_evidence
  -> Fusion_orchestrator.outcome

let log_authority_error ~keeper ~run_id ~operation error =
  Log.Keeper.error ~keeper_name:keeper
    "fusion run %s authority %s failed: %s"
    run_id operation (Fusion_run_authority.error_to_string error)
;;

let claim_first ~authority ~keeper ~run_id phase =
  match Fusion_run_authority.commit_phase authority ~keeper ~run_id phase with
  | Ok Fusion_run_authority.First_committed -> true
  | Ok Fusion_run_authority.Already_same
  | Ok (Fusion_run_authority.Conflict _) -> false
  | Error error ->
    let detail = Fusion_run_authority.error_to_string error in
    log_authority_error ~keeper ~run_id ~operation:"phase commit" error;
    Fusion_run_registry.mark_completed (Fusion_run_registry.global ()) ~run_id
      ~failure:detail ~failure_code:"authority_failed" ~ok:false ();
    Fusion_wake_route.discard ~run_id;
    false
;;

let handle_with_runtime_result ~compute ~project ~fork ~authority ~sw ~net ~base_dir
      ~keeper ~now_unix ~run_id ~policy ?continuation_channel ~args () : Tool_result.result =
  let tool_name = "masc_fusion" in
  let prompt = Tool_args.get_string args "prompt" "" in
  let preset = Tool_args.get_string args "preset" policy.Fusion_policy.default_preset in
  let web_tools = Tool_args.get_bool args "web_tools" false in
  (* topology: keeper가 합성 위상을 이름으로 선택(합성-by-selection, RFC-0252 §13 P2).
     typed 파서 fail-closed — 닫힌 합 밖은 에러 상태 반환(Unknown→permissive default 회피).
     default wire 문자열은 typed 값에서 파생한다 — 리터럴 "simple"을 중복하면 wire rename
     시 default가 조용히 drift한다(적대 리뷰 #22087 §2). *)
  let default_topology_str =
    Fusion_types.fusion_topology_to_string Fusion_types.Simple
  in
  let topology_str = Tool_args.get_string args "topology" default_topology_str in
  match
    ( String.equal (String.trim prompt) ""
    , Fusion_types.fusion_topology_of_string topology_str )
  with
  | true, _ ->
    status_result
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~ok:false
      [ "error", `String "prompt is required" ]
  | _, None ->
    status_result
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~ok:false
      [ ( "error"
        , `String
            (Printf.sprintf "topology must be one of: %s"
               (String.concat ", " Fusion_types.all_fusion_topology_strings)) )
      ]
  | false, Some topology ->
    let request : Fusion_types.fusion_request =
      { run_id
      ; keeper
      ; prompt
      ; preset
      ; web_tools
      ; depth = Fusion_types.Fusion_depth.Top
      ; trigger = Fusion_types.Explicit_tool_call
      }
    in
    match Fusion_policy.decide ~policy request with
    | Fusion_types.Deny reason ->
      status_result
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~ok:false
        [ ("status", `String "denied")
        ; ("reason", `String (Fusion_types.deny_reason_label reason))
        ]
    | Fusion_types.Allow allowed ->
      (match
         Fusion_run_authority.register authority ~topology ~request:allowed
           ~started_at:now_unix
       with
       | Error error ->
         let message = Fusion_run_authority.error_to_string error in
         log_authority_error ~keeper ~run_id ~operation:"registration" error;
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:false
           [ "error", `String message ]
       | Ok (Fusion_run_authority.Already_registered (Registered_run _)) ->
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:true
           [ "status", `String "fusion_already_running"; "run_id", `String run_id ]
       | Ok
           (Fusion_run_authority.Already_registered
              (Computation_committed_run _ | Stopped_without_computation_run _)) ->
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:true
           [ "status", `String "fusion_already_settled"; "run_id", `String run_id ]
       | Ok Fusion_run_authority.Registered ->
         let cancellation exn bt =
           let detail = Printexc.to_string exn in
           Eio.Cancel.protect (fun () ->
             if
               claim_first ~authority ~keeper ~run_id
                 (Fusion_run_authority.Stopped_without_computation (Cancelled detail))
             then (
               Fusion_run_registry.mark_completed (Fusion_run_registry.global ()) ~run_id
                 ~failure:detail ~failure_code:"cancelled" ~ok:false ();
               Fusion_wake_route.discard ~run_id));
           Printexc.raise_with_backtrace exn bt
         in
         let abort detail =
           if
            claim_first ~authority ~keeper ~run_id
               (Fusion_run_authority.Stopped_without_computation (Aborted detail))
           then
             append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"aborted"
               (Printf.sprintf "**Fusion run `%s`** _(aborted: %s)_" run_id detail)
         in
         let run_background () =
           match compute ~sw ~net ~policy ~topology ~request:allowed () with
           | exception (Eio.Cancel.Cancelled _ as exn) ->
             cancellation exn (Printexc.get_raw_backtrace ())
           | exception exn -> abort (Printexc.to_string exn)
           | Fusion_orchestrator.Compute_denied reason ->
             let detail = Fusion_types.deny_reason_label reason in
             if
               claim_first ~authority ~keeper ~run_id
                 (Fusion_run_authority.Stopped_without_computation (Denied reason))
             then
               append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"denied"
                 (Printf.sprintf "**Fusion run `%s`** _(compute denied: %s)_" run_id detail)
           | Fusion_orchestrator.Computed evidence ->
             if
               claim_first ~authority ~keeper ~run_id
                 (Fusion_run_authority.Computation_committed evidence)
             then
               (match project ~base_dir ~topology ~request:allowed evidence with
                | Fusion_orchestrator.Completed _ -> ()
                | Fusion_orchestrator.Denied reason ->
                  append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"sink_failed"
                    (Printf.sprintf "**Fusion run `%s`** _(projection denied: %s)_" run_id
                       (Fusion_types.deny_reason_label reason))
                | Fusion_orchestrator.Sink_failed msg ->
                  append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"sink_failed"
                    (Printf.sprintf "**Fusion run `%s`** _(sink failed: %s)_" run_id msg)
                | exception (Eio.Cancel.Cancelled _ as exn) ->
                  let bt = Printexc.get_raw_backtrace () in
                  Fusion_wake_route.discard ~run_id;
                  Printexc.raise_with_backtrace exn bt
                | exception exn ->
                  append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"sink_failed"
                    (Printf.sprintf "**Fusion run `%s`** _(projection failed: %s)_" run_id
                       (Printexc.to_string exn)))
         in
         (try
            Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id
              ~keeper ~preset:allowed.preset ~started_at:now_unix;
            Option.iter
              (fun channel -> Fusion_wake_route.register ~run_id channel)
              continuation_channel;
            Fusion_sink.broadcast_run_status ~registry:(Fusion_run_registry.global ()) ~run_id;
            fork run_background;
            status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:true
              [ ("status", `String "fusion_started")
              ; ("run_id", `String run_id)
              ; ( "delivery"
                , `String
                    "async: you will be woken with the result when deliberation \
                     completes; the conclusion (or failure reason) also lands on \
                     your chat lane. No need to poll masc_fusion_status." )
              ]
          with
          | Eio.Cancel.Cancelled _ as exn ->
            cancellation exn (Printexc.get_raw_backtrace ())
          | exn ->
            let detail = Printexc.to_string exn in
            abort detail;
            status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:false
              [ "error", `String detail ]))

let handle_result ~sw ~net ~authority ~base_dir ~keeper ~now_unix ~run_id ~policy
      ?continuation_channel ~args () =
  handle_with_runtime_result ~compute:Fusion_orchestrator.compute
    ~project:Fusion_orchestrator.project ~fork:(fun fn -> Eio.Fiber.fork ~sw fn)
    ~authority ~sw ~net ~base_dir ~keeper ~now_unix ~run_id ~policy
    ?continuation_channel ~args ()

let handle ~sw ~net ~authority ~base_dir ~keeper ~now_unix ~run_id ~policy
      ?continuation_channel ~args () : string =
  Tool_result.message
    (handle_result
       ~sw
       ~net
       ~authority
       ~base_dir
       ~keeper
       ~now_unix
       ~run_id
       ~policy
       ?continuation_channel
       ~args
       ())

module For_test = struct
  type nonrec computation = computation
  type nonrec projection = projection

  let handle_with_runtime ~compute ~project ~fork ~sw ~net ~authority ~base_dir
        ~keeper ~now_unix ~run_id ~policy ?continuation_channel ~args () =
    Tool_result.message
      (handle_with_runtime_result
         ~compute
         ~project
         ~fork
         ~sw
         ~net
         ~authority
         ~base_dir
         ~keeper
         ~now_unix
         ~run_id
         ~policy
         ?continuation_channel
         ~args
         ())
end
