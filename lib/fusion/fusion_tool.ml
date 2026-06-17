(* Fusion — masc_fusion 키퍼 도구 핸들러 로직 (구현).
   계약/문서: fusion_tool.mli, docs/rfc/RFC-0252 §4/§6 *)

let budget = Fusion_budget.create ()

let hour_bucket_of_unix (t : float) : string =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour

let status_json ~ok fields =
  Yojson.Safe.to_string (`Assoc (("ok", `Bool ok) :: fields))

let handle ~sw ~net ~base_dir ~keeper ~now_unix ~run_id ~policy ~args : string =
  let prompt = Tool_args.get_string args "prompt" "" in
  let preset = Tool_args.get_string args "preset" policy.Fusion_policy.default_preset in
  if String.equal (String.trim prompt) "" then
    status_json ~ok:false [ ("error", `String "prompt is required") ]
  else begin
    let hour_bucket = hour_bucket_of_unix now_unix in
    let request : Fusion_types.fusion_request =
      { run_id
      ; keeper
      ; prompt
      ; preset
      ; depth = Fusion_types.Fusion_depth.Top
      ; trigger = Fusion_types.Explicit_tool_call
      }
    in
    let denied reason =
      status_json ~ok:false
        [ ("status", `String "denied")
        ; ("reason", `String (Fusion_types.deny_reason_label reason))
        ]
    in
    match Fusion_policy.decide ~policy request with
    | Fusion_types.Deny reason -> denied reason
    | Fusion_types.Allow allowed ->
      (* 게이트 통과 후 예산을 원자적으로 소모(검사+증가가 단일 CAS라 deny는 예산을
         쓰지 않고, 멀티 도메인 동시 발동에도 per_hour_budget 초과 없음). 동기 호출
         이라 키퍼가 즉시 Over_hourly_budget를 통보받는다(fork 후 거부 아님). *)
      (match
         Fusion_budget.try_incr_if_under budget ~hour_bucket
           ~limit:policy.Fusion_policy.per_hour_budget
       with
       | Error () -> denied Fusion_types.Over_hourly_budget
       | Ok (_ : int) ->
      (* out-of-band: daemon fiber → 키퍼 턴은 즉시 진행, 결과는 sink가 chat lane에.
         호출자는 이 fiber가 키퍼 턴보다 오래 살도록 root switch를 sw로 넘긴다
         (turn switch면 턴 종료 시 심의가 취소됨).

         fork_daemon은 서버 수명(root switch)에 묶인 fire-and-forget의 관용구
         (board_dispatch/pulse/transition_audit과 동일). 단 fork/fork_daemon 모두
         본문에서 *탈출하는* 예외는 `Switch.fail sw`로 변환된다(eio fiber.ml:24/43).
         sw가 공유 root이므로 그 fail은 서버 전체를 취소시킨다 → 본문은 Cancelled
         포함 모든 예외를 흡수하고 `Stop_daemon으로 정상 종료한다. Cancelled 재전파
         (Eio 일반 규약)는 advisory 배경 작업에선 불필요하고, 공유 root에선 유해. *)
      Eio.Fiber.fork_daemon ~sw (fun () ->
        (match Fusion_orchestrator.run ~sw ~net ~base_dir ~policy ~request:allowed () with
         | Fusion_orchestrator.Completed _ | Fusion_orchestrator.Denied _ -> ()
         | exception Eio.Cancel.Cancelled _ ->
           (* 서버 teardown 신호. 재전파하면 fork_daemon이 root를 Switch.fail. *)
           ()
         | exception exn ->
           (* 배경 fiber 격리: 키퍼/서버는 죽이지 않되 침묵하지 않는다 — run_id와
              함께 기록해 started-but-failed 심의가 추적 가능하게 한다. *)
           Log.Keeper.warn ~keeper_name:keeper "fusion run %s aborted: %s" run_id
             (Printexc.to_string exn));
        `Stop_daemon);
      status_json ~ok:true
        [ ("status", `String "fusion_started"); ("run_id", `String run_id) ])
  end
