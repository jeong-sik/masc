(* Fusion — 심의 결과 가시화 (구현).
   계약/문서: fusion_sink.mli, docs/rfc/RFC-0252 §8 *)

let render_decision (d : Fusion_types.judge_decision) : string =
  match d with
  | Fusion_types.Answer a -> Printf.sprintf "answer — %s" a
  | Fusion_types.Recommend { action; rationale } ->
    Printf.sprintf "recommend — %s (%s)" action rationale
  | Fusion_types.Insufficient { missing_for_decision } ->
    Printf.sprintf "insufficient — missing: %s" (String.concat ", " missing_for_decision)

let render_judge (j : Fusion_types.judge_synthesis) : string =
  (* 명시적 구조분해 — judge_synthesis에 필드가 추가되면 이 패턴이 컴파일 에러를
     내어 렌더 누락을 강제 감지한다(레코드 dot-access는 미사용 필드를 경고하지
     않으므로, 7필드 전부 소비됨을 타입으로 보장). *)
  let { Fusion_types.consensus; contradictions; partial_coverage; unique_insights
      ; blind_spots; resolved_answer; decision } = j
  in
  let buf = Buffer.create 512 in
  let add = Buffer.add_string buf in
  add "**[judge]** synthesis\n\n";
  if consensus <> [] then begin
    add "**Consensus**\n";
    List.iter
      (fun (c : Fusion_types.claim) ->
        add
          (Printf.sprintf "- %s (models: %s)\n" c.text
             (String.concat ", " c.supporting_models)))
      consensus;
    add "\n"
  end;
  if contradictions <> [] then begin
    add "**Contradictions**\n";
    List.iter
      (fun (c : Fusion_types.contradiction) ->
        let pos =
          List.map (fun (m, s) -> Printf.sprintf "%s=%s" m s) c.positions
          |> String.concat " / "
        in
        add (Printf.sprintf "- %s: %s\n" c.topic pos))
      contradictions;
    add "\n"
  end;
  if partial_coverage <> [] then begin
    add "**Partial coverage**\n";
    List.iter
      (fun (g : Fusion_types.coverage_gap) ->
        let missing =
          match g.missing with Some m -> ": " ^ m | None -> "" (* 미상이면 생략 *)
        in
        add
          (Printf.sprintf "- %s (addressed by: %s)%s\n" g.gap_topic
             (String.concat ", " g.addressed_by) missing))
      partial_coverage;
    add "\n"
  end;
  if unique_insights <> [] then begin
    add "**Unique insights**\n";
    List.iter
      (fun (i : Fusion_types.insight) ->
        add (Printf.sprintf "- %s (%s)\n" i.insight_text i.from_model))
      unique_insights;
    add "\n"
  end;
  if blind_spots <> [] then begin
    add "**Blind spots**\n";
    List.iter (fun b -> add (Printf.sprintf "- %s\n" b)) blind_spots;
    add "\n"
  end;
  add (Printf.sprintf "**Resolved answer**\n%s\n\n" resolved_answer);
  add (Printf.sprintf "**Decision**: %s\n" (render_decision decision));
  Buffer.contents buf

(* board post 증거의 보존 기간. 심의 증거는 transient 알림(24h)보다 오래 둬 사후
   리뷰가 가능하도록 1주로 둔다 (Magic Number 회피 — named 상수). *)
let board_post_ttl_hours = 24 * 7

(* 패널 결과를 board meta_json 원소로. chat lane이 아니라 여기(board)가 패널 답변
   *서사*를 담는 surface다 (키퍼 observation 도배 방지, RFC §8.1 개정). 답변 텍스트와
   실측 토큰을 함께 남긴다. *)
let panel_meta (o : Fusion_types.panel_outcome) : Yojson.Safe.t =
  match o with
  | Fusion_types.Answered { model; answer; usage; _ } ->
    `Assoc
      [ ("model", `String model)
      ; ("status", `String "answered")
      ; ("answer", `String answer)
      ; ("input_tokens", `Int usage.Fusion_types.input_tokens)
      ; ("output_tokens", `Int usage.Fusion_types.output_tokens)
      ]
  | Fusion_types.Failed { failed_model; reason } ->
    `Assoc
      [ ("model", `String failed_model)
      ; ("status", `String "failed")
      ; ("reason", `String (Fusion_types.show_panel_failure reason))
      ]

(* 심판 결과를 board meta_json 원소로. *)
let judge_meta (judge : (Fusion_types.judge_synthesis, string) result) : Yojson.Safe.t =
  (* status는 형제 panel_meta와 같은 동사형(판이 무엇을 했는가): 종합 산출은
     "synthesized", 실패는 "failed". tool-result ok-봉투("ok")가 아니라 board
     증거의 judge 서술 필드다 (no-inline-ok-envelope 가드 대상과 별개 개념). *)
  match judge with
  | Ok j ->
    `Assoc
      [ ("status", `String "synthesized")
      ; ("decision", `String (render_decision j.Fusion_types.decision))
      ; ("resolved_answer", `String j.Fusion_types.resolved_answer)
      ; ("synthesis", `String (render_judge j))
      ]
  | Error e -> `Assoc [ ("status", `String "failed"); ("error", `String e) ]

(* RFC-0266: 심의 완료 시 호출 키퍼를 typed [Fusion_completed] stimulus로 깨운다.
   board post + chat append(영속)와 별개로, 잠든(Running) 키퍼를 즉시 깨워
   resolved_answer가 다음 턴의 actionable 입력으로 도착하게 하는 hint+payload 경로다.
   예외 안전: registry 문제로 sink 결과/실패 알림이 오염되면 안 되므로 자체 흡수하되
   Eio 구조적 취소(Cancelled)는 재전파한다(record_recovery_stimulus_turn_started 패턴).
   Paused 키퍼는 강제 재개하지 않는다(board wake와 동일 보수적 기본값, wakeup_keeper가
   Running 항목만 깨움) — 결과는 board/chat 영속으로 남는다. *)
let wake_keeper_on_fusion_completion
      ~base_dir ~keeper ~run_id ~ok ~resolved_answer ~board_post_id =
  try
    let fusion_completion =
      Keeper_event_queue.{ run_id; ok; resolved_answer; board_post_id }
    in
    let post_id = Keeper_event_queue.fusion_completion_post_id fusion_completion in
    let stimulus : Keeper_event_queue.stimulus =
      { Keeper_event_queue.post_id
      ; urgency = Keeper_event_queue.Normal
      ; arrived_at = Time_compat.now ()
      ; payload = Keeper_event_queue.Fusion_completed fusion_completion
      }
    in
    Log.Keeper.info "fusion completion wake: keeper=%s run_id=%s ok=%b" keeper run_id ok;
    Keeper_keepalive_signal.wakeup_keeper ~base_path:base_dir ~stimulus keeper
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn ~keeper_name:keeper "fusion completion wake failed run_id=%s: %s"
      run_id
      (Printexc.to_string exn)

let emit ~base_dir ~keeper ~run_id ~question ~panel ~judge ~judge_usage :
    (unit, string) result =
  try
    (* 비용 관측(제약 아님) — 패널 N + 심판 1 실측 토큰 합산 (RFC §10). board 증거에만
       남긴다 (cost cap은 v1 제외, 측정값만 — 괴상한 제약 제거 원칙). 실패한 패널/심판은
       완성이 없어 0(usage_of가 완성 응답에서만 토큰을 뽑음). *)
    let panel_usage =
      List.fold_left
        (fun acc (o : Fusion_types.panel_outcome) ->
          match o with
          | Fusion_types.Answered a -> Fusion_types.add_usage acc a.usage
          | Fusion_types.Failed _ -> acc)
        Fusion_types.zero_usage panel
    in
    let total_usage = Fusion_types.add_usage panel_usage judge_usage in
    (* board post — 패널 답변 전체 + 심판 종합을 쿼리 가능한 구조화 증거(meta_json)로.
       사용자는 대시보드 board에서 상세를 본다. chat lane *서사*를 board로 옮긴 것이
       RFC §8.1 대비 변경점(키퍼 observation 도배 방지). 실패는 [Error]로 orchestrator에. *)
    let board_headline =
      match judge with
      | Ok j ->
        Printf.sprintf "Fusion deliberation (run %s): %s" run_id
          (render_decision j.Fusion_types.decision)
      | Error _ -> Printf.sprintf "Fusion deliberation (run %s): judge failed" run_id
    in
    let meta_json =
      Some
        (`Assoc
           [ ("source", `String "fusion")
           ; ("run_id", `String run_id)
           ; ("question", `String question)
           ; ("panel", `List (List.map panel_meta panel))
           ; ("judge", judge_meta judge)
           ; ( "observed_usage"
             , `Assoc
                 [ ("input_tokens", `Int total_usage.Fusion_types.input_tokens)
                 ; ("output_tokens", `Int total_usage.Fusion_types.output_tokens)
                 ] )
           ])
    in
    (* board post를 *먼저* 만들어 post id를 확보한다 — 이 id가 키퍼 chat의 fusion block
       lazy-fetch 키이기 때문이다(대시보드가 board meta_json에서 패널/심판을 펼친다). *)
    let board_result =
      Board_dispatch.create_post ~author:keeper ~content:board_headline
        ~post_kind:Board.System_post ?meta_json ~visibility:Board.Internal
        ~ttl_hours:board_post_ttl_hours ()
    in
    (* 키퍼 메인 흐름 통합 ("결과를 키퍼 흐름에 녹이기", RFC-0252 §8 개정).
       상세 트랜스크립트(패널 답변 N개)는 위 board post 증거로만 남기고, 키퍼 chat
       lane에는 judge 결론(decision + resolved_answer)만 키퍼 *메인* conversation
       (conversation_id 생략)에 append한다. board가 생성됐으면 그 post를 가리키는
       [Fusion] block을 함께 첨부해 대시보드가 결론 카드를 패널/심판 상세로 펼치게 한다.
       block은 content가 아니므로 키퍼 observation(recent_direct_conversation, role/content만
       읽음)을 도배하지 않는다 → librarian은 메인 chat 결론(content)을 fact로 추출하고,
       사용자만 카드 상세를 본다(강결합 없는 통합). judge 실패 시에는 메인 흐름을
       오염시키지 않으려 결론을 남기지 않는다(board에는 실패도 증거로 남는다). *)
    (match judge with
     | Ok j ->
       let content =
         Printf.sprintf "Fusion deliberation (run %s) — %s\n\n%s" run_id
           (render_decision j.Fusion_types.decision) j.Fusion_types.resolved_answer
       in
       let blocks =
         match board_result with
         | Ok (post : Board.post) ->
           Some
             [ Keeper_chat_blocks.Fusion
                 { board_post_id = Board.Post_id.to_string post.id; run_id }
             ]
         | Error _ -> None
         (* board 생성 실패 시 카드 링크를 생략하되 결론은 남긴다(키퍼가 인지). *)
       in
       Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper
         ~content ?blocks ();
       Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
         ~content
         ()
     | Error _ -> ());
    (* RFC-0266: completion 성공 경로(board post 생성됨)에서만 깨운다. board 생성
       실패(Error)는 orchestrator가 [Sink_failed]로 바꿔 fusion_tool의
       append_chat_failure가 깨우므로, 여기서도 깨우면 중복 wake가 된다. judge가
       Error여도 fusion은 끝났으니 ok=false로 통지한다(board엔 실패도 증거로 남음). *)
    (match board_result with
     | Ok post ->
       let ok, resolved_answer =
         match judge with
         | Ok j -> true, j.Fusion_types.resolved_answer
         | Error e -> false, Printf.sprintf "judge failed: %s" e
       in
       wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok ~resolved_answer
         ~board_post_id:(Board.Post_id.to_string post.id);
       Ok ()
     | Error e -> Error (Board.show_board_error e))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
