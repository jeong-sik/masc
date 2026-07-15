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

let record_completion ~keeper ~run_id ?failure ?failure_code ~ok () =
  match
    Fusion_run_registry.mark_completed (Fusion_run_registry.global ()) ~operation_id:run_id
      ?failure ?failure_code ~ok ()
  with
  | Ok () -> ()
  | Error error ->
    Log.Keeper.error ~keeper_name:keeper
      "fusion completion receipt error run_id=%s: %s"
      run_id
      (Fusion_run_registry.completion_error_to_string error)
;;

let append_chat_failure ~base_dir ~keeper ~run_id ~failure_code content =
  (* 실패 알림도 성공 결론(fusion_sink.emit)과 동일하게 키퍼 *메인* conversation에
     남긴다(conversation_id 생략). recent_direct_conversation observation 필터는
     conversation_id를 보지 않고 role/kind만 보므로
     (keeper_world_observation_message_scope.ml:recent_direct_conversation_of_messages),
     별도 "fusion/<run_id>" 스레드는 메인 오염을 막지 못하면서 한 run의 성공/실패만
     다른 lane으로 흩어지는 split-brain을 만든다. denied/sink_failed/aborted는 키퍼가
     다음 턴에 인지해야 할 운영 실패이므로 메인 lane이 옳다(run_id는 content에 포함). *)
  (* RFC-0266 §7: 종료 상태(Completed{ok=false})를 아래 chat append 이전에 확정한다.
     completion receipt 실패는 registry의 typed [Persistence_failed]로 남고 명시 로그된다.
     아래 append는 Eio 파일 I/O라 셧다운/형제 fiber Switch.fail 시 Cancelled를
     재전파(아래 with 분기)하며 함수를 빠져나간다. finalize를 append *뒤* 에 두면 그 경로에서
     run이 registry([global], 서버 수명)에 "running"으로 남는다(prune는 Running을 evict 안 함
     — fusion_run_registry.ml). 순수 프로세스 셧다운이면 global이 프로세스와 함께 소멸하므로,
     *영구* 잔존은 프로세스가 살아남는 형제 Switch.fail/sub-switch 취소에 한한다. #21784는
     orchestrator-level Cancelled(handle fork match)
     만 막았고 이 내부 append window는 못 막았다. Denied/Sink_failed/aborted 종료 분기가 모두
     이 함수를 경유하므로 같은 누수의 형제 경로다. *)
  record_completion ~keeper ~run_id ~failure:content ~failure_code ~ok:false ();
  (try
     Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper ~content ();
     Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
       ~content
       ()
   with
   | Eio.Cancel.Cancelled _ as exn ->
     (* 구조적 취소는 재전파. registry는 위에서 이미 Completed로 확정됨. *)
     raise exn
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

type orchestrator_runner =
  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> base_dir:string
  -> policy:Fusion_policy.t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> unit
  -> Fusion_orchestrator.outcome

let handle_with_runner_result ~run_orchestrator ~sw ~net ~base_dir ~keeper ~now_unix ~run_id
      ~policy ?continuation_channel ~args () : Tool_result.result =
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
      let operation : Fusion_types.fusion_operation = { request = allowed; topology } in
      (* RFC-0266 §7: 진행중 가시성을 위해 fork 직전 run을 Running으로 등록한다
         (sink/실패 경로가 Completed로 갱신). Durable register가 실패하면 worker를
         시작하지 않는다. 시작했지만 복구할 receipt가 없는 상태를 만들 수 없기
         때문이다. *)
      (match
         Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~operation
           ~started_at:now_unix
       with
       | Error error ->
         status_result
           ~tool_name
           ~class_:Tool_result.Runtime_failure
           ~ok:false
           [ ("status", `String "persistence_failed")
           ; ("run_id", `String run_id)
           ; ( "error"
             , `String (Fusion_run_registry.persistence_error_to_string error) )
           ]
       | Ok () ->
      let channel =
        Option.value continuation_channel
          ~default:(Keeper_continuation_channel.unrouted "no originating connector")
      in
      (match Fusion_wake_route.register ~operation_id:run_id ~owner:keeper ~channel with
       | Error error ->
         let reason = Fusion_wake_route.error_to_string error in
         record_completion ~keeper ~run_id ~failure:reason
           ~failure_code:"completion_address_persistence_failed" ~ok:false ();
         Fusion_sink.broadcast_run_status ~registry:(Fusion_run_registry.global ()) ~run_id;
         status_result ~tool_name ~class_:Tool_result.Runtime_failure ~ok:false
           [ ("status", `String "persistence_failed")
           ; ("run_id", `String run_id)
           ; ("error", `String reason)
           ]
       | Ok _ ->
      (* RFC-0266 §7 Phase 4: push the new [Running] card to the dashboard panel
         (no polling). wake-free, broadcast-failure-safe; see
         Fusion_sink.broadcast_run_status. *)
      Fusion_sink.broadcast_run_status ~registry:(Fusion_run_registry.global ()) ~run_id;
      (* out-of-band: fiber fork → 키퍼 턴은 즉시 진행, 결과는 sink가 chat lane에.
         배경 fiber 실패/거부/싱크 실패는 동일한 chat lane에 기록해 started-but-failed
         상태가 남지 않도록 한다. 호출자는 이 fiber가 키퍼 턴보다 오래 살아도록 root
         switch를 sw로 넘긴다 (turn switch면 턴 종료 시 심의가 취소됨). *)
      Eio.Fiber.fork ~sw (fun () ->
        match
          run_orchestrator ~sw ~net ~base_dir ~policy ~topology ~request:allowed ()
        with
        | Fusion_orchestrator.Completed _ -> ()
        | Fusion_orchestrator.Denied reason ->
          append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"denied"
            (Printf.sprintf "**Fusion run `%s`** _(denied after start: %s)_" run_id
               (Fusion_types.deny_reason_label reason))
        | Fusion_orchestrator.Sink_failed msg ->
          append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"sink_failed"
            (Printf.sprintf "**Fusion run `%s`** _(sink failed: %s)_" run_id msg)
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          (* RFC-0266 §7: 취소도 종료 상태다. register_running(위 line 73)으로 [Running]
             으로 등록된 run을 [Completed{ok=false}]로 갱신하지 않으면, in-memory registry
             ([global], 서버 수명)에 영구 "running"으로 남아 dashboard fusion-runs 패널과
             masc_fusion_status가 거짓 "심의중"을 보인다(prune는 [Running]을 evict하지 않음 —
             fusion_run_registry.ml). 다른 종료 분기(Denied/Sink_failed/exception)는
             append_chat_failure 경유로 이미 mark_completed 하는데 이 분기만 빠져 있었다.
             completion receipt 실패도 registry에 typed state로 남는다. broadcast는
             [Sse.broadcast]가 mailbox에서 suspend/block할 수 있어
             취소/셧다운 캐스케이드를 deadlock시킬 위험이 있으므로 이 경로에선 생략한다 —
             registry가 정확해 다음 HTTP fetch / tab-refresh가 패널을 self-heal한다.
             그 뒤 구조적 취소는 흡수하지 않고 재전파한다 (Eio 규약). *)
          let cancellation =
            "cancelled: structural cancellation (shutdown or sibling switch failure)"
          in
          record_completion ~keeper ~run_id ~failure:cancellation
            ~failure_code:"cancelled" ~ok:false ();
          (match
             Fusion_wake_route.queue_completion ~operation_id:run_id ~ok:false
               ~content:cancellation ~evidence_ref:None
           with
           | Ok _ -> ()
           | Error error ->
             Log.Keeper.error ~keeper_name:keeper
               "fusion cancellation completion queue failed run_id=%s: %s" run_id
               (Fusion_wake_route.error_to_string error));
          raise exn
        | exception exn ->
          append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"aborted"
            (Printf.sprintf "**Fusion run `%s`** _(aborted: %s)_" run_id
               (Printexc.to_string exn)));
      (* [delivery] 필드는 도구 결과의 async 계약을 명시한다: 완료 시 키퍼는
         [Fusion_completed] wake로 깨워지고 결론/실패 사유가 chat lane에 durable하게
         남는다. 2026-07-01 관측: 이 계약이 결과 JSON에 없어서 키퍼들이 3-5초 간격
         masc_fusion_status 폴링으로 턴을 소모했다(8 run에 35 poll + nudge 8회). *)
      status_result
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~ok:true
        [ ("status", `String "fusion_started")
        ; ("run_id", `String run_id)
        ; ( "delivery"
          , `String
              "async: you will be woken with the result when deliberation \
               completes; the conclusion (or failure reason) also lands on \
               your chat lane. No need to poll masc_fusion_status." )
        ]))

let handle_result ~sw ~net ~base_dir ~keeper ~now_unix ~run_id ~policy
      ?continuation_channel ~args () =
  handle_with_runner_result ~run_orchestrator:Fusion_orchestrator.run ~sw ~net ~base_dir
    ~keeper ~now_unix ~run_id ~policy ?continuation_channel ~args ()

let handle ~sw ~net ~base_dir ~keeper ~now_unix ~run_id ~policy ?continuation_channel
      ~args () : string =
  Tool_result.message
    (handle_result
       ~sw
       ~net
       ~base_dir
       ~keeper
       ~now_unix
       ~run_id
       ~policy
       ?continuation_channel
       ~args
       ())

module For_test = struct
  type nonrec orchestrator_runner = orchestrator_runner

  let handle_with_runner ~run_orchestrator ~sw ~net ~base_dir ~keeper ~now_unix
        ~run_id ~policy ?continuation_channel ~args () =
    Tool_result.message
      (handle_with_runner_result
         ~run_orchestrator
         ~sw
         ~net
         ~base_dir
         ~keeper
         ~now_unix
         ~run_id
         ~policy
         ?continuation_channel
         ~args
         ())
end
