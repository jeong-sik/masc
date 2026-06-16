(* Fusion — masc_fusion 키퍼 도구 핸들러 로직 (구현).
   계약/문서: fusion_tool.mli, docs/rfc/RFC-0249 §4/§6 *)

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
  let web_tools = Tool_args.get_bool args "web_tools" false in
  if String.equal (String.trim prompt) "" then
    status_json ~ok:false [ ("error", `String "prompt is required") ]
  else begin
    let hour_bucket = hour_bucket_of_unix now_unix in
    (* deny가 예산을 소모하지 않도록 먼저 peek. 단일 도메인 협력 스케줄링에서
       peek→incr 사이 yield가 없어 원자적(추가 동기화 불필요). *)
    let hourly_count = Fusion_budget.current_count budget ~hour_bucket in
    let request : Fusion_types.fusion_request =
      { run_id
      ; keeper
      ; prompt
      ; preset
      ; depth = Fusion_types.Fusion_depth.Top
      ; trigger = Fusion_types.Explicit_tool_call
      ; web_tools
      }
    in
    match Fusion_policy.decide ~policy ~hourly_count ~estimated_cost_usd:0.0 request with
    | Fusion_types.Deny reason ->
      status_json ~ok:false
        [ ("status", `String "denied")
        ; ("reason", `String (Fusion_types.deny_reason_label reason))
        ]
    | Fusion_types.Allow allowed ->
      (* Allow일 때만 예산 소모. *)
      let _ : int = Fusion_budget.incr_and_count budget ~hour_bucket in
      (* out-of-band: fiber fork → 키퍼 턴은 즉시 진행, 결과는 sink가 chat lane에. *)
      Eio.Fiber.fork ~sw (fun () ->
        match Fusion_orchestrator.run ~sw ~net ~base_dir ~policy ~hourly_count ~request:allowed () with
        | _ -> ()
        | exception exn ->
          (* 배경 fiber 예외 격리 — 키퍼/서버를 죽이지 않는다. *)
          ignore exn);
      status_json ~ok:true
        [ ("status", `String "fusion_started"); ("run_id", `String run_id) ]
  end
