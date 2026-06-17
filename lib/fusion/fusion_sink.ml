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

let emit ~base_dir ~keeper ~run_id ~question ~panel ~judge ~judge_usage :
    (unit, string) result =
  try
    (* 키퍼 메인 흐름 통합 ("결과를 키퍼 흐름에 녹이기", RFC-0252 §8 개정).
       상세 트랜스크립트(패널 답변 N개)는 아래 board post 증거로만 남기고, 키퍼 chat
       lane에는 judge 결론(decision + resolved_answer)만 키퍼 *메인* conversation
       (conversation_id 생략)에 append한다. → 키퍼 observation(recent_direct_conversation)이
       패널 답변으로 도배되지 않고, librarian이 메인 chat 결론을 fact로 추출한다(memory-os
       fact 타입에 직접 의존하지 않음 = 강결합 없는 통합). judge 실패 시에는 메인 흐름을
       오염시키지 않으려 결론을 남기지 않는다(board에는 실패도 증거로 남는다). *)
    (match judge with
     | Ok j ->
       Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper
         ~content:
           (Printf.sprintf "Fusion deliberation (run %s) — %s\n\n%s" run_id
              (render_decision j.Fusion_types.decision) j.Fusion_types.resolved_answer)
         ();
       Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
     | Error _ -> ());
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
    (match
       Board_dispatch.create_post ~author:keeper ~content:board_headline
         ~post_kind:Board.System_post ?meta_json ~visibility:Board.Internal
         ~ttl_hours:board_post_ttl_hours ()
     with
     | Ok _post -> Ok ()
     | Error e -> Error (Board.show_board_error e))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
