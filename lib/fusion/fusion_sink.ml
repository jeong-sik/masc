(* Fusion — 심의 결과 가시화 (구현).
   계약/문서: fusion_sink.mli, docs/rfc/RFC-0255 §8 *)

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

let render_panel (o : Fusion_types.panel_outcome) : string =
  match o with
  | Fusion_types.Answered { model; answer; _ } -> Printf.sprintf "**[%s]**\n%s" model answer
  | Fusion_types.Failed { failed_model; reason } ->
    Printf.sprintf "**[%s]** _(failed: %s)_" failed_model
      (Fusion_types.show_panel_failure reason)

(* board post 증거의 보존 기간. 심의 증거는 transient 알림(24h)보다 오래 둬 사후
   리뷰가 가능하도록 1주로 둔다 (Magic Number 회피 — named 상수). *)
let board_post_ttl_hours = 24 * 7

let usage_meta (u : Fusion_types.usage) : Yojson.Safe.t =
  `Assoc
    [ ("input_tokens", `Int u.Fusion_types.input_tokens)
    ; ("output_tokens", `Int u.Fusion_types.output_tokens)
    ]

(* 패널 결과를 board meta_json 원소로. RFC-0255 §8.2 shape:
   { "model": "...", "answer": "...", "confidence": 0.0, "usage": {...} } *)
let panel_meta (o : Fusion_types.panel_outcome) : Yojson.Safe.t =
  match o with
  | Fusion_types.Answered { model; answer; confidence; usage } ->
    `Assoc
      [ ("model", `String model)
      ; ("status", `String "answered")
      ; ("answer", `String answer)
      ; ( "confidence"
        , match confidence with Some c -> `Float c | None -> `Float 0.0 )
      ; ("usage", usage_meta usage)
      ]
  | Fusion_types.Failed { failed_model; reason } ->
    `Assoc
      [ ("model", `String failed_model)
      ; ("status", `String "failed")
      ; ("reason", `String (Fusion_types.show_panel_failure reason))
      ]

let claim_meta (c : Fusion_types.claim) : Yojson.Safe.t =
  `Assoc
    [ ("text", `String c.text)
    ; ("supporting_models", `List (List.map (fun m -> `String m) c.supporting_models))
    ]

let position_meta ((model, stance) : string * string) : Yojson.Safe.t =
  `Assoc [ ("model", `String model); ("stance", `String stance) ]

let contradiction_meta (c : Fusion_types.contradiction) : Yojson.Safe.t =
  `Assoc
    [ ("topic", `String c.topic)
    ; ("positions", `List (List.map position_meta c.positions))
    ; ("evidence", `List (List.map (fun e -> `String e) c.evidence))
    ]

let coverage_meta (g : Fusion_types.coverage_gap) : Yojson.Safe.t =
  `Assoc
    [ ("topic", `String g.gap_topic)
    ; ("addressed_by", `List (List.map (fun m -> `String m) g.addressed_by))
    ; ( "missing"
      , match g.missing with Some m -> `String m | None -> `Null )
    ]

let insight_meta (i : Fusion_types.insight) : Yojson.Safe.t =
  `Assoc [ ("text", `String i.insight_text); ("model", `String i.from_model) ]

let decision_meta (d : Fusion_types.judge_decision) : Yojson.Safe.t =
  match d with
  | Fusion_types.Answer answer ->
    `Assoc [ ("kind", `String "answer"); ("answer", `String answer) ]
  | Fusion_types.Recommend { action; rationale } ->
    `Assoc
      [ ("kind", `String "recommend")
      ; ("action", `String action)
      ; ("rationale", `String rationale)
      ]
  | Fusion_types.Insufficient { missing_for_decision } ->
    `Assoc
      [ ("kind", `String "insufficient")
      ; ("missing", `List (List.map (fun s -> `String s) missing_for_decision))
      ]

(* 심판 결과를 board meta_json 원소로. RFC-0255 §8.2 judge shape. *)
let judge_meta ~(judge_model : string)
    (judge : (Fusion_types.judge_synthesis, string) result) : Yojson.Safe.t =
  match judge with
  | Ok j ->
    `Assoc
      [ ("model", `String judge_model)
      ; ("status", `String "synthesized")
      ; ("consensus", `List (List.map claim_meta j.Fusion_types.consensus))
      ; ( "contradictions"
        , `List (List.map contradiction_meta j.Fusion_types.contradictions) )
      ; ( "partial_coverage"
        , `List (List.map coverage_meta j.Fusion_types.partial_coverage) )
      ; ( "unique_insights"
        , `List (List.map insight_meta j.Fusion_types.unique_insights) )
      ; ("blind_spots", `List (List.map (fun b -> `String b) j.Fusion_types.blind_spots))
      ; ("resolved_answer", `String j.Fusion_types.resolved_answer)
      ; ("decision", decision_meta j.Fusion_types.decision)
      ]
  | Error e -> `Assoc [ ("status", `String "failed"); ("error", `String e) ]

let emit ~base_dir ~keeper ~run_id ~preset ~trigger ~question ~panel ~judge
    ~judge_model ~start_time_unix : (unit, string) result =
  let conversation_id = "fusion/" ^ run_id in
  try
    let append content =
      Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper ~content
        ~conversation_id ()
    in
    append
      (Printf.sprintf "**Fusion deliberation** (run `%s`)\n\n**Question**\n%s" run_id
         question);
    List.iter (fun o -> append (render_panel o)) panel;
    (* 비용 관측(제약 아님) — 패널이 실제 사용한 토큰을 합산해 표시한다. cost cap은
       v1에서 제외(추정기 부재)하고, 측정값만 남긴다 (괴상한 제약 제거 원칙). *)
    let total_usage =
      List.fold_left
        (fun acc (o : Fusion_types.panel_outcome) ->
          match o with
          | Fusion_types.Answered a -> Fusion_types.add_usage acc a.usage
          | Fusion_types.Failed _ -> acc)
        Fusion_types.zero_usage panel
    in
    append
      (Printf.sprintf "**Observed usage** — input=%d output=%d tokens (panel)"
         total_usage.Fusion_types.input_tokens total_usage.Fusion_types.output_tokens);
    (match judge with
     | Ok j -> append (render_judge j)
     | Error e -> append (Printf.sprintf "**[judge]** _(failed: %s)_" e));
    (* 모든 append 후 한 번 브로드캐스트 — 대시보드가 키퍼 chat을 재조회해 전체 표시. *)
    Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion";
    (* board post — 구조화 증거(meta_json). chat lane은 사람이 읽는 *서사*,
       board는 run_id로 묶인 쿼리 가능한 *증거*다. 사용자 가시성 요구는 두 surface
       모두(RFC-0255 §3/§8.2). 실패는 [Error]로 상위(orchestrator)에 전달한다. *)
    let board_headline =
      match judge with
      | Ok j ->
        Printf.sprintf "Fusion deliberation (run %s): %s" run_id
          (render_decision j.Fusion_types.decision)
      | Error _ -> Printf.sprintf "Fusion deliberation (run %s): judge failed" run_id
    in
    let latency_ms =
      let elapsed = Unix.gettimeofday () -. start_time_unix in
      int_of_float (elapsed *. 1000.0)
    in
    let meta_json =
      Some
        (`Assoc
           [ ( "fusion_deliberation"
             , `Assoc
                 [ ("run_id", `String run_id)
                 ; ("preset", `String preset)
                 ; ("trigger", `String (Fusion_types.trigger_label trigger))
                 ; ("panel", `List (List.map panel_meta panel))
                 ; ("judge", judge_meta ~judge_model judge)
                 ; ("cost_usd", `Float 0.0)
                 ; ("latency_ms", `Int latency_ms)
                 ] )
           ])
    in
    (match
       Board_dispatch.create_post ~author:keeper ~content:board_headline
         ~post_kind:Board.System_post ?meta_json ~visibility:Board.Internal
         ~ttl_hours:board_post_ttl_hours ()
     with
     | Ok _post ->
       Ok () (* [Board_dispatch.create_post] returns [Board.post], not unit. *)
     | Error e -> Error (Board.show_board_error e))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
