(* Fusion — 심판 (구현).
   계약/문서: fusion_judge.mli, docs/rfc/RFC-0249 §7.2

   일반 에이전트 실행(Fusion_oas) + Fusion_judge_parse(LLM-facing JSON). *)

let judge_system_prompt =
  "You are an impartial judge. You are given a panel of model answers to the \
   same question. Synthesize them: identify points of consensus, \
   contradictions, partial coverage, unique insights, and blind spots, then \
   give one resolved answer. Respond with ONLY the requested JSON object, no \
   prose and no code fences."

let compose_prompt ~question ~panel =
  let answers =
    Fusion_types.answered_of panel
    |> List.map (fun (a : Fusion_types.panel_answer) ->
           Printf.sprintf "### Panel model: %s\n%s" a.model a.answer)
    |> String.concat "\n\n"
  in
  Printf.sprintf "QUESTION:\n%s\n\nPANEL ANSWERS:\n%s\n\n%s" question answers
    Fusion_judge_parse.expected_json_doc

let run ~sw ~net ?(timeout_s = 120.0) ~judge_model ~question ~panel ()
  : (Fusion_types.judge_synthesis, string) result
  =
  match Fusion_oas.build_agent ~sw ~net ~system_prompt:judge_system_prompt judge_model with
  | Error reason ->
    Error
      (Printf.sprintf "judge build failed: %s"
         (Fusion_types.show_panel_failure reason))
  | Ok agent ->
    let prompt = compose_prompt ~question ~panel in
    (match
       Masc_oas_bridge.run_safe ~caller:"fusion_judge" ~timeout_s (fun () ->
         Ok (Agent_sdk.Async_agent.all ~sw [ (agent, prompt) ]))
     with
     | Error e -> Error ("judge run failed: " ^ Agent_sdk.Error.to_string e)
     | Ok [] -> Error "judge: empty result"
     | Ok ((_name, Ok resp) :: _) ->
       let text = Fusion_oas.answer_text resp in
       if String.length (String.trim text) = 0 then Error "judge: empty response"
       else Fusion_judge_parse.of_string text
     | Ok ((_name, Error e) :: _) ->
       Error ("judge provider error: " ^ Agent_sdk.Error.to_string e))
