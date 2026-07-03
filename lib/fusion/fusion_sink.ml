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

(* RFC-0252 §7/§8 — board meta_json의 judge 원소에서 구조화 종합(5섹션 + recommend/
   missing)을 보존한다. 프론트(FusionJudgeEvidence, keeper-v2 fusion.jsx)가
   consensus/contradictions/partial_coverage/unique_insights/blind_spots 섹션을
   렌더하려면 이 필드들이 JSON에 있어야 한다 — synthesis markdown만 내보내면
   프론트가 markdown을 재파싱해야 하는 string 분류기 안티패턴이 되므로 근본 fix는
   구조화 그 자체를 직렬화하는 것이다.
   ppx [@@deriving yojson]이 [judge_synthesis_to_yojson]을 자동 생성하지만, 그 결과는
   OCaml 레코드 필드명(gap_topic/supporting_models/insight_text/from_model)을 그대로
   JSON 키로 쓴다 — keeper-v2 스키마와 [fusion_judge_parse.ml]의 LLM-facing JSON 스키마
   (topic/addressed_by/text/model)과 불일치. 그래서 parse(of_json)과 대칭되는
   emit(to_json)을 수동으로 두어 SSOT를 LLM-facing 스키마로 정립한다. *)
let claim_to_json (c : Fusion_types.claim) : Yojson.Safe.t =
  `Assoc
    [ ("text", `String c.Fusion_types.text)
    ; ( "models"
      , `List (List.map (fun m -> `String m) c.Fusion_types.supporting_models) )
    ]

let contradiction_to_json (c : Fusion_types.contradiction) : Yojson.Safe.t =
  (* positions은 튜플 (model, stance) 리스트를 keeper-v2 스키마의 [[model, stance]]
     배열로 직렬화 — 프론트 normalizeContradictionPositions의 Array 분기와 대칭. *)
  `Assoc
    [ ("topic", `String c.Fusion_types.topic)
    ; ( "positions"
      , `List
          (List.map
             (fun (m, stance) -> `Assoc [ ("model", `String m); ("stance", `String stance) ])
             c.Fusion_types.positions) )
    ]

let coverage_gap_to_json (g : Fusion_types.coverage_gap) : Yojson.Safe.t =
  (* missing : string option. 미상(None)은 null — 빈 문자열로 압축하지 않는다
     (fusion_types.ml 주석). 프론트는 falsy missing을 가진 gap을 스킵하므로 렌더
     누락이 아니라 의도적 생략이다. *)
  `Assoc
    [ ("topic", `String g.Fusion_types.gap_topic)
    ; ( "addressed_by"
      , `List (List.map (fun m -> `String m) g.Fusion_types.addressed_by) )
    ; ("missing", match g.Fusion_types.missing with Some m -> `String m | None -> `Null)
    ]

let insight_to_json (i : Fusion_types.insight) : Yojson.Safe.t =
  `Assoc
    [ ("text", `String i.Fusion_types.insight_text)
    ; ("model", `String i.Fusion_types.from_model)
    ]

let recommendation_to_json (r : Fusion_types.recommendation) : Yojson.Safe.t =
  `Assoc
    [ ("action", `String r.Fusion_types.action)
    ; ("rationale", `String r.Fusion_types.rationale)
    ]

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
    let reason_code = Fusion_oas.panel_failure_code reason in
    (* reason detail은 실패 시점에 raw model로 이미 attribution됐다. 여기서
       ~runtime_id:failed_model(=panelist)로 재-attribution하면 "skeptic (claude)"
       같은 정체성이 provider 슬롯에 새거나 중복 prefix가 붙는다 (RFC-0278). *)
    let reason_detail = Fusion_oas.panel_failure_text reason in
    `Assoc
      [ ("model", `String failed_model)
      ; ("status", `String "failed")
      ; ("reason_code", `String reason_code)
      ; ("reason_detail", `String reason_detail)
      ; ("reason", `String reason_detail)
      ]

(* judge_synthesis → board meta_json 필드 리스트 (status/decision/resolved_answer/
   synthesis + 구조화 5섹션 + decision-variant 최상위 recommend|missing). judge_meta
   (canonical [judge] 키)와 judge_node_meta(관측 [judges] 배열, RFC-0284)가 공유한다 —
   같은 5섹션 직렬화(키 매핑 gap_topic→topic 등)를 두 번 짜면 한쪽만 회귀하므로 추출
   (N-of-M 회피). test_fusion_sink_meta.ml이 이 매핑을 핀한다. *)
let judge_synthesis_fields (j : Fusion_types.judge_synthesis) :
  (string * Yojson.Safe.t) list =
  let { Fusion_types.consensus; contradictions; partial_coverage; unique_insights
      ; blind_spots; resolved_answer; decision } =
    j
  in
  (* base 7필드: status/decision/resolved_answer/synthesis(평탄화 markdown, 호환) +
     구조화 5섹션. synthesis를 남기는 건 구형 프론트/로그 호환 — 구조화 필드가
     canonical이므로 신규 프론트는 5섹션을 우선 소비한다. *)
  let base =
    [ ("status", `String "synthesized")
    ; ("decision", `String (render_decision decision))
    ; ("resolved_answer", `String resolved_answer)
    ; ("synthesis", `String (render_judge j))
    ; ("consensus", `List (List.map claim_to_json consensus))
    ; ("contradictions", `List (List.map contradiction_to_json contradictions))
    ; ("partial_coverage", `List (List.map coverage_gap_to_json partial_coverage))
    ; ("unique_insights", `List (List.map insight_to_json unique_insights))
    ; ("blind_spots", `List (List.map (fun b -> `String b) blind_spots))
    ]
  in
  (* decision variant에 따라 keeper-v2 스키마의 최상위 recommend/missing를 붙인다.
     Answer → 추가 없음, Recommend → recommend:{action,rationale},
     Insufficient → missing:[...]. 프론트 normalizeRecommendation/normalizeJudge 가
     judge.recommend / judge.missing 을 읽는다. *)
  match decision with
  | Fusion_types.Recommend r -> ("recommend", recommendation_to_json r) :: base
  | Fusion_types.Insufficient { missing_for_decision } ->
    ("missing", `List (List.map (fun m -> `String m) missing_for_decision)) :: base
  | Fusion_types.Answer _ -> base

(* 심판 종합을 board meta_json [judge] 원소로 (canonical 단일 키 — RFC-0284 이전 호환). *)
let judge_meta (judge : (Fusion_types.judge_synthesis, Fusion_types.judge_failure) result)
    : Yojson.Safe.t =
  (* status는 형제 panel_meta와 같은 동사형(판이 무엇을 했는가): 종합 산출은
     "synthesized", 실패는 "failed". tool-result ok-봉투("ok")가 아니라 board
     증거의 judge 서술 필드다 (no-inline-ok-envelope 가드 대상과 별개 개념). *)
  match judge with
  | Ok j -> `Assoc (judge_synthesis_fields j)
  | Error f ->
    `Assoc
      [ ("status", `String "failed")
      ; ("error", `String (Fusion_types.judge_failure_text f))
      ; ("failure_code", `String (Fusion_types.judge_failure_tag f))
      ]

(* 심판 노드의 위상 역할/정체성 → board meta_json 필드 (RFC-0284). [role]은 위상 의미
   (single/refine/first/meta/stage_meta/final_meta), [identity]는 [First]면 panelist_id(panel
   model과 대칭), [Stage_meta n]이면 stage-n. 프론트는 role로 노드 종류를, identity로 1차
   심판·stage를 구분해 위상 이름 없이 배열 shape만으로 구조를 렌더한다. *)
let judge_role_fields (role : Fusion_types.judge_role) : (string * Yojson.Safe.t) list =
  let kind, identity =
    match role with
    | Fusion_types.Single -> ("single", "single")
    | Fusion_types.Refine_pass -> ("refine", "refine")
    | Fusion_types.First id -> ("first", id)
    | Fusion_types.Meta -> ("meta", "meta")
    | Fusion_types.Stage_meta n -> ("stage_meta", Printf.sprintf "stage-%d" n)
    | Fusion_types.Final_meta -> ("final_meta", "final")
  in
  [ ("role", `String kind); ("identity", `String identity) ]

(* 심판 실행 노드 한 건을 board meta_json [judges] 배열 원소로 (RFC-0284). panel_meta와
   동형: [Synthesized] → role/identity + judge_synthesis 5섹션 + 노드별 실측 usage,
   [Judge_failed] → role/identity + status="failed" + error + 노드별 실측 usage(RFC-0284 E:
   실패한 심판도 토큰을 태웠으면 관측 record에 비용을 남긴다). *)
let judge_node_meta (o : Fusion_types.judge_outcome) : Yojson.Safe.t =
  match o with
  | Fusion_types.Synthesized { role; synthesis; usage } ->
    `Assoc
      (judge_role_fields role
       @ judge_synthesis_fields synthesis
       @ [ ("input_tokens", `Int usage.Fusion_types.input_tokens)
         ; ("output_tokens", `Int usage.Fusion_types.output_tokens)
         ])
  | Fusion_types.Judge_failed { failed_role; failure; usage; elapsed_s } ->
    (* [failure]가 single source of truth. 하위 호환을 위해 사람-가독 [error] 문자열과
       파생 [timed_out]을 synthetic key로 복원하고, 정확 분류용 [failure_code]를 additive
       로 추가한다(dashboard는 [error]만 읽고 [timed_out]/[elapsed_s]는 무시하므로 기존
       소비가 깨지지 않는다). *)
    let timed_out = Fusion_types.judge_failure_is_timeout failure in
    `Assoc
      (judge_role_fields failed_role
       @ [ ("status", `String "failed")
         ; ("error", `String (Fusion_types.judge_failure_text failure))
         ; ("failure_code", `String (Fusion_types.judge_failure_tag failure))
         ; ("input_tokens", `Int usage.Fusion_types.input_tokens)
         ; ("output_tokens", `Int usage.Fusion_types.output_tokens)
         ; ("elapsed_s", `Float elapsed_s)
         ; ("timed_out", `Bool timed_out)
         ])

(* RFC-0266: 심의 완료 시 호출 키퍼를 typed [Fusion_completed] stimulus로 깨운다.
   board post + chat append(영속)와 별개로, 잠든(Running) 키퍼를 즉시 깨워
   resolved_answer가 다음 턴의 actionable 입력으로 도착하게 하는 hint+payload 경로다.
   예외 안전: registry 문제로 sink 결과/실패 알림이 오염되면 안 되므로 자체 흡수하되
   Eio 구조적 취소(Cancelled)는 재전파한다(record_recovery_stimulus_turn_started 패턴).
   Paused 키퍼는 강제 재개하지 않는다(board wake와 동일 보수적 기본값, wakeup_keeper가
   Running 항목만 깨움) — 결과는 board/chat 영속으로 남는다. *)
(* RFC-0266 §7 Phase 4: push the registry delta to the dashboard fusion-runs
   panel so a [Running] card flips to completed/failed live (no polling). Reads
   the canonical run back from the registry and serializes it through the shared
   [Fusion_run_registry.run_to_yojson] so the SSE payload matches the HTTP list
   endpoint exactly. Like wake, this is best-effort: a broadcast failure must not
   abort the fusion sink, so every non-cancel exception is swallowed + logged
   (mirrors Keeper_chat_broadcast). An unknown run_id is a no-op. *)
let broadcast_run_status ~registry ~run_id =
  try
    match Fusion_run_registry.get registry ~run_id with
    | None -> ()
    | Some run ->
      Sse.broadcast
        (`Assoc
           [ ("type", `String "fusion_run_status")
           ; ("run", Fusion_run_registry.run_to_yojson run)
           ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn "fusion_run_broadcast run_id=%s failed: %s" run_id
      (Printexc.to_string exn)

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

let emit ~base_dir ~keeper ~run_id ~question ~panel ~judge ~judges ~judge_usage :
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
    (* 실패한 패널의 per-panel 사유 요약. 실패 headline/chat이 이걸 나르지 않으면
       사유는 meta_json에만 남는데, 키퍼 도구(masc_board_post_get)는 title/body만
       렌더하므로 키퍼가 원인에 도달할 tool-reachable 경로가 없다 (2026-07-01:
       "0 of 3 panels answered"만 보고 judge 메커니즘 고장으로 오진, 수 시간 소모). *)
    let failed_panel_lines =
      panel
      |> List.filter_map (fun (o : Fusion_types.panel_outcome) ->
             match o with
             | Fusion_types.Answered _ -> None
             | Fusion_types.Failed { failed_model; reason } ->
               Some
                 (Printf.sprintf "- %s: %s" failed_model
                    (Fusion_oas.panel_failure_text reason)))
    in
    let render_failure f =
      let base =
        Printf.sprintf "%s: %s"
          (Fusion_types.judge_failure_tag f)
          (Fusion_types.judge_failure_text f)
      in
      match failed_panel_lines with
      | [] -> base
      | lines -> base ^ "\n" ^ String.concat "\n" lines
    in
    let board_headline =
      match judge with
      | Ok j ->
        Printf.sprintf "Fusion deliberation (run %s): %s" run_id
          (render_decision j.Fusion_types.decision)
      | Error f ->
        Printf.sprintf "Fusion deliberation (run %s) failed — %s" run_id
          (render_failure f)
    in
    let meta_json =
      Some
        (`Assoc
           [ ("source", `String "fusion")
           ; ("run_id", `String run_id)
           ; ("question", `String question)
           ; ("panel", `List (List.map panel_meta panel))
           ; ("judge", judge_meta judge)
             (* RFC-0284: 실행된 심판 노드 관측 배열 (panel과 동형). 기존 단일 [judge]
                키는 canonical로 ADDITIVE 유지(구 프론트/디스크 reader 호환) — 제거는
                후속 마이그레이션. 대시보드는 이 배열 shape로 위상 구조를 렌더한다. *)
           ; ("judges", `List (List.map judge_node_meta judges))
           ; ( "observed_usage"
             , `Assoc
                 [ ("input_tokens", `Int total_usage.Fusion_types.input_tokens)
                 ; ("output_tokens", `Int total_usage.Fusion_types.output_tokens)
                 ] )
           ])
    in
    (* board post를 *먼저* 만들어 post id를 확보한다 — 이 id가 키퍼 chat의 fusion block
       lazy-fetch 키이기 때문이다(대시보드가 board meta_json에서 패널/심판을 펼친다). *)
    (* RFC-0233 §7: typed origin. [fusion_run_id] is in scope here ([run_id]),
       so a real index ([posts_by_run_id]) can key on it instead of the legacy
       meta_json substring. [turn_ref = None]: fusion is an out-of-band
       server-root-switch fork, so the triggering keeper's turn_ref is not in
       this scope; threading it through [fusion_request] is a separate change.
       The legacy meta_json [run_id] (above) is kept ADDITIVELY this release —
       existing dashboard / on-disk readers depend on it; its removal is a
       later migration, not this PR. *)
    let origin : Board.post_origin =
      { turn_ref = None; source = Some "fusion"; fusion_run_id = Some run_id }
    in
    let board_result =
      Board_dispatch.create_post ~author:keeper ~content:board_headline
        ~post_kind:Board.System_post ?meta_json ~visibility:Board.Internal
        ~ttl_hours:board_post_ttl_hours ~origin ()
    in
    (* 키퍼 메인 흐름 통합 ("결과를 키퍼 흐름에 녹이기", RFC-0252 §8 개정).
       상세 트랜스크립트(패널 답변 N개)는 위 board post 증거로만 남기고, 키퍼 chat
       lane에는 judge 결론(decision + resolved_answer)만 키퍼 *메인* conversation
       (conversation_id 생략)에 append한다. board가 생성됐으면 그 post를 가리키는
       [Fusion] block을 함께 첨부해 대시보드가 결론 카드를 패널/심판 상세로 펼치게 한다.
       block은 content가 아니므로 키퍼 observation(recent_direct_conversation, role/content만
       읽음)을 도배하지 않는다 → librarian은 메인 chat 결론(content)을 fact로 추출하고,
       사용자만 카드 상세를 본다(강결합 없는 통합).

       judge 실패도 결론이다: 실패 사유(+ per-panel 사유)를 같은 lane에 남긴다.
       이전에는 "메인 흐름 비오염"을 이유로 실패 시 아무것도 남기지 않았는데,
       그 결과 (a) wake 일회성 preview가 유일한 사유 전달 채널이 됐고(비-Running
       키퍼면 조용히 유실 — keeper_keepalive_signal은 Running만 깨움), (b) 키퍼가
       실패 원인을 조회할 수 있는 durable 표면이 없어 폴링·오진을 유발했다
       (2026-07-01 사고). denied/sink_failed/aborted가 이미 같은 메인 lane에
       남는 것(fusion_tool.append_chat_failure)과도 정합. *)
    let chat_lane_result =
      let content =
        match judge with
        | Ok j ->
          Printf.sprintf "Fusion deliberation (run %s) — %s\n\n%s" run_id
            (render_decision j.Fusion_types.decision)
            j.Fusion_types.resolved_answer
        | Error f ->
          Printf.sprintf "Fusion deliberation (run %s) failed — %s" run_id
            (render_failure f)
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
      (* .mli 계약: chat store append 예외 시 [Error msg]를 반환한다. unit 버전은
         실패를 삼켜 emit이 Ok를 반환했었다(silent drop). [_result] 변형으로 실패를
         surface한다. 성공한 경우에만 broadcast한다. *)
      match
        Keeper_chat_store.append_assistant_message_result ~base_dir
          ~keeper_name:keeper ~content ?blocks ()
      with
      | Ok () ->
        Keeper_chat_broadcast.chat_appended ~keeper_name:keeper
          ~source:"fusion" ~content ();
        Ok ()
      | Error _ as e -> e
    in
    (* RFC-0266 (개정, board best-effort): completion 여부는 *키퍼가 결론을 받았는가*
       (chat lane)로 판정한다. board post는 증거 카드일 뿐이므로 그 생성 실패는 fatal이
       아니다. chat lane append가 성공하면 board 결과와 무관하게 여기서 한 번
       mark_completed/broadcast/wake 한다: board Ok면 카드 post id를, board Error면
       경고 로그 후 빈 id를 넘긴다(append_chat_failure의 [board_post_id:""] 선례와 대칭).
       chat lane append가 실패한 경우에만 [Error]를 반환해 orchestrator의 [Sink_failed]
       → fusion_tool.append_chat_failure가 통지하게 한다(키퍼가 결론을 못 받은 유일한
       경우). 과거엔 board Error도 [Error]로 반환해, 결론 전달이 성공했는데도
       append_chat_failure가 그 위에 모순된 "(sink failed)" note + ok=false wake를 덧대고
       (이중 통지), 완료/wake 경로 자체는 board Error 시 건너뛰던 버그가 있었다. *)
    (match chat_lane_result with
     | Error msg -> Error msg
     | Ok () ->
       let board_post_id =
         match board_result with
         | Ok (post : Board.post) -> Board.Post_id.to_string post.id
         | Error e ->
           Log.Keeper.warn ~keeper_name:keeper
             "fusion board card unavailable run_id=%s: %s" run_id
             (Board.show_board_error e);
           ""
       in
       (* RFC-0266 §7: registry를 Completed로 갱신(가시성). wake 직전 무조건 호출.
          실패 시 사유/태그를 함께 기록해 masc_fusion_status·SSE가 opaque
          "failed"가 되지 않게 한다. *)
       (match judge with
        | Ok j ->
          Fusion_run_registry.mark_completed Fusion_run_registry.global ~run_id
            ~ok:true ();
          broadcast_run_status ~registry:Fusion_run_registry.global ~run_id;
          wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok:true
            ~resolved_answer:j.Fusion_types.resolved_answer ~board_post_id
        | Error e ->
          Fusion_run_registry.mark_completed Fusion_run_registry.global ~run_id
            ~failure:(Fusion_types.judge_failure_text e)
            ~failure_code:(Fusion_types.judge_failure_tag e)
            ~ok:false ();
          broadcast_run_status ~registry:Fusion_run_registry.global ~run_id;
          wake_keeper_on_fusion_completion ~base_dir ~keeper ~run_id ~ok:false
            ~resolved_answer:
              (Printf.sprintf "fusion run failed — %s" (render_failure e))
            ~board_post_id);
       Ok ())
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
