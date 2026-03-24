(** Autoresearch_codegen — LLM-based code change generation.

    Builds prompts, parses MODEL responses containing <hypothesis> and
    <modified_code> XML tags, and invokes the cascade for code generation.

    @since 2.80.0 *)

include Autoresearch_types

(** Build prompt for MODEL code change. Exported for testing. *)
let build_code_change_prompt ~goal ~baseline ~history ~insights
    ~file_content ~target_file =
  let recent = List.filteri (fun i _ -> i < 5) history in
  let history_lines = List.map (fun (r : cycle_record) ->
    Printf.sprintf "  Cycle %d: %s -> delta=%.4f (%s)"
      r.cycle r.hypothesis r.delta (Autoresearch_serde.decision_to_string r.decision)
  ) recent in
  let insight_lines = List.map (fun s -> "  - " ^ s) insights in
  String.concat "\n" ([
    "You are an autonomous research assistant optimizing code.";
    Printf.sprintf "Goal: %s" goal;
    Printf.sprintf "Current baseline score: %.4f (higher is better)" baseline;
    Printf.sprintf "Target file: %s" target_file;
  ] @ (if history_lines <> [] then
    [""; "Recent experiment history:"] @ history_lines
  else []) @ (if insight_lines <> [] then
    [""; "Accumulated insights:"] @ insight_lines
  else []) @ [
    "";
    "<current_code>";
    file_content;
    "</current_code>";
    "";
    "Modify the code to improve the metric score.";
    "Reply with exactly:";
    "1. A <hypothesis> tag containing a one-line description of your change";
    "2. A <modified_code> tag containing the COMPLETE modified file";
    "";
    "Example format:";
    "<hypothesis>Increase batch size from 32 to 64 for better throughput</hypothesis>";
    "<modified_code>";
    "... complete file content ...";
    "</modified_code>";
  ])

(** Extract text between XML-style tags. *)
let extract_tag ~tag text =
  let open_tag = Printf.sprintf "<%s>" tag in
  let close_tag = Printf.sprintf "</%s>" tag in
  let open_len = String.length open_tag in
  let close_len = String.length close_tag in
  let text_len = String.length text in
  let rec find_start i =
    if i + open_len > text_len then None
    else if String.sub text i open_len = open_tag then
      let content_start = i + open_len in
      find_end content_start content_start
    else find_start (i + 1)
  and find_end content_start j =
    if j + close_len > text_len then None
    else if String.sub text j close_len = close_tag then
      Some (String.sub text content_start (j - content_start))
    else find_end content_start (j + 1)
  in
  find_start 0

(** Parse MODEL response containing <hypothesis> and <modified_code> tags.
    Returns Ok (hypothesis, modified_code) or Error reason. *)
let parse_model_code_response response =
  if String.trim response = "" then
    Result.error "MODEL returned empty response"
  else
    match extract_tag ~tag:"hypothesis" response with
    | None -> Result.error "Missing <hypothesis> tag in MODEL response"
    | Some h ->
      let hypothesis = String.trim h in
      if hypothesis = "" then Result.error "Empty <hypothesis> tag"
      else
        match extract_tag ~tag:"modified_code" response with
        | None -> Result.error "Missing <modified_code> tag in MODEL response"
        | Some code ->
          if String.trim code = "" then Result.error "Empty <modified_code> tag"
          else
            (* Strip all leading/trailing whitespace-only lines *)
            let trimmed =
              let lines = String.split_on_char '\n' code in
              let rec drop_blank = function
                | [] -> []
                | l :: rest ->
                  if String.trim l = "" then drop_blank rest
                  else l :: rest
              in
              let stripped = drop_blank lines in
              let stripped = List.rev (drop_blank (List.rev stripped)) in
              String.concat "\n" stripped
            in
            Result.ok (hypothesis, trimmed)

(** Generate code change via Cascade "autoresearch" profile.
    Returns Ok (hypothesis, new_code) or Error reason. *)
let generate_code_change ~goal ~baseline ~history ~insights
    ~target_file ~file_content =
  let prompt = build_code_change_prompt ~goal ~baseline ~history ~insights
    ~file_content ~target_file in
  match
    Oas_worker.run_named ~cascade_name:"autoresearch"
      ~goal:prompt ~max_turns:1
      ~temperature:(Cascade_inference.resolve_temperature
        ~cascade_name:"autoresearch" ~fallback:(fun () -> 0.7))
      ~max_tokens:(Cascade_inference.resolve_max_tokens
        ~cascade_name:"autoresearch" ~fallback:(fun () -> 4096))
      ()
  with
  | Error e -> Result.error (Printf.sprintf "MODEL call failed: %s" e)
  | Ok result -> parse_model_code_response (Oas_response.text_of_response result.Oas_worker.response)
