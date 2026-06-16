(* Fusion — 심의 결과 가시화 (구현).
   계약/문서: fusion_sink.mli, docs/rfc/RFC-0251 §8 *)

let render_decision (d : Fusion_types.judge_decision) : string =
  match d with
  | Fusion_types.Answer a -> Printf.sprintf "answer — %s" a
  | Fusion_types.Recommend { action; rationale } ->
    Printf.sprintf "recommend — %s (%s)" action rationale
  | Fusion_types.Insufficient { missing_for_decision } ->
    Printf.sprintf "insufficient — missing: %s" (String.concat ", " missing_for_decision)

let render_judge (j : Fusion_types.judge_synthesis) : string =
  let buf = Buffer.create 512 in
  let add = Buffer.add_string buf in
  add "**[judge]** synthesis\n\n";
  if j.consensus <> [] then begin
    add "**Consensus**\n";
    List.iter
      (fun (c : Fusion_types.claim) ->
        add
          (Printf.sprintf "- %s (models: %s)\n" c.text
             (String.concat ", " c.supporting_models)))
      j.consensus;
    add "\n"
  end;
  if j.contradictions <> [] then begin
    add "**Contradictions**\n";
    List.iter
      (fun (c : Fusion_types.contradiction) ->
        let pos =
          List.map (fun (m, s) -> Printf.sprintf "%s=%s" m s) c.positions
          |> String.concat " / "
        in
        add (Printf.sprintf "- %s: %s\n" c.topic pos))
      j.contradictions;
    add "\n"
  end;
  if j.blind_spots <> [] then begin
    add "**Blind spots**\n";
    List.iter (fun b -> add (Printf.sprintf "- %s\n" b)) j.blind_spots;
    add "\n"
  end;
  add (Printf.sprintf "**Resolved answer**\n%s\n\n" j.resolved_answer);
  add (Printf.sprintf "**Decision**: %s\n" (render_decision j.decision));
  Buffer.contents buf

let render_panel (o : Fusion_types.panel_outcome) : string =
  match o with
  | Fusion_types.Answered { model; answer; _ } -> Printf.sprintf "**[%s]**\n%s" model answer
  | Fusion_types.Failed { failed_model; reason } ->
    Printf.sprintf "**[%s]** _(failed: %s)_" failed_model
      (Fusion_types.show_panel_failure reason)

let emit ~base_dir ~keeper ~run_id ~question ~panel ~judge : unit =
  let conversation_id = "fusion/" ^ run_id in
  let append content =
    Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name:keeper ~content
      ~conversation_id ()
  in
  append
    (Printf.sprintf "**Fusion deliberation** (run `%s`)\n\n**Question**\n%s" run_id
       question);
  List.iter (fun o -> append (render_panel o)) panel;
  (match judge with
   | Ok j -> append (render_judge j)
   | Error e -> append (Printf.sprintf "**[judge]** _(failed: %s)_" e));
  (* 모든 append 후 한 번 브로드캐스트 — 대시보드가 키퍼 chat을 재조회해 전체 표시. *)
  Keeper_chat_broadcast.chat_appended ~keeper_name:keeper ~source:"fusion"
