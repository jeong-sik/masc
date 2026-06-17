(* Fusion — masc_fusion 키퍼 도구 핸들러 로직 (구현).
   계약/문서: fusion_tool.mli, docs/rfc/RFC-0255 §4/§6 *)

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
  try
    Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper ~content ();
    Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
  with
  | Eio.Cancel.Cancelled _ as exn ->
    (* 구조적 취소는 재전파. *)
    raise exn
  | exn ->
    Log.Keeper.warn ~keeper_name:keeper
      "fusion run %s failed to append failure message: %s" run_id
      (Printexc.to_string exn)

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
          (* 구조적 취소는 흡수하지 않고 재전파 (Eio 규약). *)
          raise exn
        | exception exn ->
          append_chat_failure ~base_dir ~keeper ~run_id
            (Printf.sprintf "**Fusion run `%s`** _(aborted: %s)_" run_id
               (Printexc.to_string exn)));
      status_json ~ok:true
        [ ("status", `String "fusion_started"); ("run_id", `String run_id) ]
  end
