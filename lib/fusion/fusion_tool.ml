(* Fusion — masc_fusion 키퍼 도구 핸들러 로직 (구현).
   계약/문서: fusion_tool.mli, docs/rfc/RFC-0252 §4/§6 *)

let budget = Fusion_budget.create ()

let hour_bucket_of_unix (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour

let status_json ~ok fields =
  Yojson.Safe.to_string (`Assoc (("ok", `Bool ok) :: fields))

let append_chat_failure ~base_dir ~keeper ~run_id content =
  (* 실패 알림도 성공 결론(fusion_sink.emit)과 동일하게 키퍼 *메인* conversation에
     남긴다(conversation_id 생략). recent_direct_conversation observation 필터는
     conversation_id를 보지 않고 role/kind만 보므로
     (keeper_world_observation_message_scope.ml:recent_direct_conversation_of_messages),
     별도 "fusion/<run_id>" 스레드는 메인 오염을 막지 못하면서 한 run의 성공/실패만
     다른 lane으로 흩어지는 split-brain을 만든다. denied/sink_failed/aborted는 키퍼가
     다음 턴에 인지해야 할 운영 실패이므로 메인 lane이 옳다(run_id는 content에 포함). *)
  (try
     Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper ~content ();
     Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
       ~content
       ()
   with
   | Eio.Cancel.Cancelled _ as exn ->
     (* 구조적 취소는 재전파. *)
     raise exn
   | exn ->
     Log.Keeper.warn ~keeper_name:keeper
       "fusion run %s failed to append failure message: %s" run_id
       (Printexc.to_string exn));
  (* RFC-0266: 실패도 호출 키퍼를 ok=false로 깨워 "결과 안 옴" 폴링 대신 능동 통지한다
     (성공 경로의 fusion_sink.emit wake와 대칭). content가 실패 사유 라벨이 된다.
     wake는 자체 예외 안전하므로 chat append 실패와 독립적으로 시도된다. *)
  (* RFC-0266 §7: registry를 Completed{ok=false}로 갱신(가시성). wake와 무관하게
     run 상태를 반영해야 하므로 별도 호출(Running 키퍼만 깨우는 wake와 달리 무조건). *)
  Fusion_run_registry.mark_completed Fusion_run_registry.global ~run_id ~ok:false;
  Fusion_sink.broadcast_run_status ~registry:Fusion_run_registry.global ~run_id;
  Fusion_sink.wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok:false
    ~resolved_answer:content ~board_post_id:""

let handle ~sw ~net ~base_dir ~keeper ~now_unix ~run_id ~policy ~args : string =
  let prompt = Tool_args.get_string args "prompt" "" in
  let preset = Tool_args.get_string args "preset" policy.Fusion_policy.default_preset in
  let web_tools = Tool_args.get_bool args "web_tools" false in
  if String.equal (String.trim prompt) "" then
    status_json ~ok:false [ ("error", `String "prompt is required") ]
  else begin
    let hour_bucket = hour_bucket_of_unix now_unix in
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
      Fusion_run_registry.register_running Fusion_run_registry.global ~run_id ~keeper
        ~preset ~started_at:now_unix;
      (* RFC-0266 §7 Phase 4: push the new [Running] card to the dashboard panel
         (no polling). wake-free, broadcast-failure-safe; see
         Fusion_sink.broadcast_run_status. *)
      Fusion_sink.broadcast_run_status ~registry:Fusion_run_registry.global ~run_id;
      (* out-of-band: fiber fork → 키퍼 턴은 즉시 진행, 결과는 sink가 chat lane에.
         예산은 orchestrator가 원자적으로 소비한다. 배경 fiber 실패/거부/싱크
         실패는 동일한 chat lane에 기록해 started-but-failed 상태가 남지 않도록 한다.
         호출자는 이 fiber가 키퍼 턴어보다 오래 살아도록 root switch를 sw로 넘긴다
         (turn switch면 턴 종료 시 심의가 취소됨). *)
      Eio.Fiber.fork ~sw (fun () ->
        match
          Fusion_orchestrator.run ~sw ~net ~base_dir ~budget ~hour_bucket ~policy
            ~request:allowed ()
        with
        | Fusion_orchestrator.Completed _ -> ()
        | Fusion_orchestrator.Denied reason ->
          append_chat_failure ~base_dir ~keeper ~run_id
            (Printf.sprintf "**Fusion run `%s`** _(denied after start: %s)_" run_id
               (Fusion_types.deny_reason_label reason))
        | Fusion_orchestrator.Sink_failed msg ->
          append_chat_failure ~base_dir ~keeper ~run_id
            (Printf.sprintf "**Fusion run `%s`** _(sink failed: %s)_" run_id msg)
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          (* RFC-0266 §7: 취소도 종료 상태다. register_running(위 line 73)으로 [Running]
             으로 등록된 run을 [Completed{ok=false}]로 갱신하지 않으면, in-memory registry
             ([global], 서버 수명)에 영구 "running"으로 남아 dashboard fusion-runs 패널과
             masc_fusion_status가 거짓 "심의중"을 보인다(prune는 [Running]을 evict하지 않음 —
             fusion_run_registry.ml). 다른 종료 분기(Denied/Sink_failed/exception)는
             append_chat_failure 경유로 이미 mark_completed 하는데 이 분기만 빠져 있었다.
             [mark_completed]는 순수 in-memory CAS(suspension 없음)라 취소 컨텍스트에서도
             안전하다. broadcast는 [Sse.broadcast]가 mailbox에서 suspend/block할 수 있어
             취소/셧다운 캐스케이드를 deadlock시킬 위험이 있으므로 이 경로에선 생략한다 —
             registry가 정확해 다음 HTTP fetch / tab-refresh가 패널을 self-heal한다.
             그 뒤 구조적 취소는 흡수하지 않고 재전파한다 (Eio 규약). *)
          Fusion_run_registry.mark_completed Fusion_run_registry.global ~run_id ~ok:false;
          raise exn
        | exception exn ->
          append_chat_failure ~base_dir ~keeper ~run_id
            (Printf.sprintf "**Fusion run `%s`** _(aborted: %s)_" run_id
               (Printexc.to_string exn)));
      status_json ~ok:true
        [ ("status", `String "fusion_started"); ("run_id", `String run_id) ]
  end
