(* Fusion — masc_fusion 키퍼 도구 핸들러 로직 (구현).
   계약/문서: fusion_tool.mli, docs/rfc/RFC-0252 §4/§6 *)

let status_json ~ok fields =
  Yojson.Safe.to_string (`Assoc (("ok", `Bool ok) :: fields))

let structural_cancel_failure_code = "cancelled"

let structural_cancel_failure =
  "cancelled: structural cancellation (shutdown or sibling switch failure)"

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
  Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok:false
    ~resolved_answer:content ~board_post_id:""

let finalize_cancelled_run ~base_dir ~keeper ~run_id =
  (* [mark_completed] is non-yielding registry state, so run visibility is
     closed before any protected suspending cleanup starts. *)
  Fusion_run_registry.mark_completed (Fusion_run_registry.global ()) ~run_id
    ~failure:structural_cancel_failure
    ~failure_code:structural_cancel_failure_code
    ~ok:false
    ();
  try
    Eio.Cancel.protect (fun () ->
      Fusion_sink.broadcast_run_status ~registry:(Fusion_run_registry.global ()) ~run_id;
      Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok:false
        ~resolved_answer:structural_cancel_failure ~board_post_id:"")
  with
  | Eio.Cancel.Cancelled _ as cleanup_exn ->
    Log.Keeper.warn ~keeper_name:keeper
      "fusion cancelled finalizer was cancelled during protected cleanup run_id=%s: %s"
      run_id
      (Printexc.to_string cleanup_exn)

let handle ~sw ~net ~base_dir ~keeper ~now_unix ~run_id ~policy ~args : string =
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
  | true, _ -> status_json ~ok:false [ ("error", `String "prompt is required") ]
  | _, None ->
    status_json ~ok:false
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
      status_json ~ok:false
        [ ("status", `String "denied")
        ; ("reason", `String (Fusion_types.deny_reason_label reason))
        ]
    | Fusion_types.Allow allowed ->
      (* RFC-0266 §7: 진행중 가시성을 위해 fork 직전 run을 Running으로 등록한다
         (sink/실패 경로가 Completed로 갱신). 등록은 부수효과 없는 in-memory 기록일
         뿐, 키퍼를 깨우지 않는다(wake는 별개). *)
      Fusion_run_registry.register_running (Fusion_run_registry.global ()) ~run_id ~keeper
        ~preset ~started_at:now_unix;
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
          Fusion_orchestrator.run ~sw ~net ~base_dir ~policy ~topology
            ~request:allowed ()
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
          (* RFC-0266 §7: 취소도 종료 상태이며 결과 전달 계약의 일부다. Registry는
             non-yielding 상태로 먼저 닫고, dashboard broadcast + typed
             [Fusion_completed] wake는 Eio's protected cleanup context에서 시도한다.
             원래 구조적 취소는 흡수하지 않고 아래에서 그대로 재전파한다. *)
          finalize_cancelled_run ~base_dir ~keeper ~run_id;
          raise exn
        | exception exn ->
          append_chat_failure ~base_dir ~keeper ~run_id ~failure_code:"aborted"
            (Printf.sprintf "**Fusion run `%s`** _(aborted: %s)_" run_id
               (Printexc.to_string exn)));
      (* [delivery] 필드는 도구 결과의 async 계약을 명시한다: 완료 시 키퍼는
         [Fusion_completed] wake로 깨워지고 결론/실패 사유가 chat lane에 durable하게
         남는다. 2026-07-01 관측: 이 계약이 결과 JSON에 없어서 키퍼들이 3-5초 간격
         masc_fusion_status 폴링으로 턴을 소모했다(8 run에 35 poll + nudge 8회). *)
      status_json ~ok:true
        [ ("status", `String "fusion_started")
        ; ("run_id", `String run_id)
        ; ( "delivery"
          , `String
              "async: you will be woken with the result when deliberation \
               completes; the conclusion (or failure reason) also lands on \
               your chat lane. No need to poll masc_fusion_status." )
        ]
