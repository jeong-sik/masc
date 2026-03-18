open Printf

let ( let* ) value f = match value with Ok x -> f x | Error _ as err -> err

type status =
  | Acted
  | Skipped
  | Failed

type completion = {
  status : status;
  summary : string;
  decision_reason : string;
  decision_confidence : float;
  tool_call_count : int;
  tool_names : string list;
  worker_name : string;
  model_used : string;
  output : string;
  failure_reason : string option;
}

let status_to_string = function
  | Acted -> "acted"
  | Skipped -> "skipped"
  | Failed -> "failed"

let status_of_string = function
  | "acted" -> Ok Acted
  | "skipped" -> Ok Skipped
  | "failed" -> Ok Failed
  | other -> Error (sprintf "unsupported worker status: %s" other)

let trim_opt = function
  | None -> None
  | Some text ->
      let trimmed = String.trim text in
      if trimmed = "" then None else Some trimmed

let default_allowed_tools ~allow_post =
  Agent_tool_surfaces.lodge_worker_base_tool_names ~allow_post ()

let uniq items =
  let rec loop seen = function
    | [] -> List.rev seen
    | x :: xs ->
        if List.mem x seen then loop seen xs else loop (x :: seen) xs
  in
  loop [] items

let allowed_tools ~allow_post ?(extra = []) () =
  uniq (default_allowed_tools ~allow_post @ extra)

let mcp_base_url () =
  Env_config.masc_http_base_url ()

let worker_model_spec () =
  let explicit =
    match Sys.getenv_opt "MASC_LODGE_WORKER_MODEL" with
    | Some raw when String.trim raw <> "" -> Some (String.trim raw)
    | _ -> None
  in
  match explicit with
  | Some spec -> Llm.model_spec_of_string spec
  | None -> (
      match Sys.getenv_opt "LLAMA_SWARM_MODEL" with
      | Some raw when String.trim raw <> "" ->
          Llm.model_spec_of_string ("llama:" ^ String.trim raw)
      | _ ->
          Llm.model_spec_of_string
            ("llama:" ^ Env_config.Llama.default_model))

let base_path () =
  Room_utils.resolve_masc_base_path (Sys.getcwd ())

let extract_json_object = Lodge_decision.extract_json_object

let parse_confidence = function
  | `Float f -> Ok f
  | `Int i -> Ok (float_of_int i)
  | _ -> Error "decision_confidence must be numeric"

let parse_completion_json (text : string) : (completion, string) result =
  let open Yojson.Safe.Util in
  let* json_text = extract_json_object text in
  let* json =
    try Ok (Yojson.Safe.from_string json_text)
    with Yojson.Json_error msg -> Error (sprintf "invalid worker JSON: %s" msg)
  in
  let* status =
    match json |> member "status" with
    | `String s -> status_of_string (String.lowercase_ascii (String.trim s))
    | _ -> Error "status must be a string"
  in
  let* summary =
    match json |> member "summary" with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then Error "summary must be non-empty" else Ok trimmed
    | _ -> Error "summary must be a string"
  in
  let* decision_reason =
    match json |> member "decision_reason" with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then Error "decision_reason must be non-empty" else Ok trimmed
    | _ -> Error "decision_reason must be a string"
  in
  let* decision_confidence =
    match parse_confidence (json |> member "decision_confidence") with
    | Ok value when value >= 0.0 && value <= 1.0 -> Ok value
    | Ok _ -> Error "decision_confidence must be between 0.0 and 1.0"
    | Error _ as err -> err
  in
  let failure_reason =
    json |> member "failure_reason" |> to_string_option |> trim_opt
  in
  Ok
    {
      status;
      summary;
      decision_reason;
      decision_confidence;
      tool_call_count = 0;
      tool_names = [];
      worker_name = "";
      model_used = "";
      output = text;
      failure_reason;
    }

let action_tool_names =
  [ "masc_board_post"; "masc_board_comment"; "masc_board_vote"; "masc_board_comment_vote" ]

let acted_by_tools tool_names =
  List.exists (fun name -> List.mem name action_tool_names) tool_names

let default_summary tool_names =
  if tool_names = [] then "No tools executed."
  else sprintf "Executed tools: %s" (String.concat ", " tool_names)

let default_reason tool_names =
  if acted_by_tools tool_names then "worker acted via MCP tools"
  else "worker inspected context and chose not to act"

let build_prompt ~agent_name ~identity_prompt ~goal ~context =
  sprintf
    {|You are Lodge agent %s.

Identity context:
%s

Goal:
%s

Operational context:
%s

Use the provided MASC MCP tools directly.
Decide for yourself which tools to call, in what order, and whether to act or skip.
If you act, the action must happen via tools, not prose.
If you skip, explain why.

When you are done, return JSON only:
{
  "status": "acted|skipped|failed",
  "summary": "what you actually did, or why you skipped",
  "decision_reason": "why this choice fit your identity and the context",
  "decision_confidence": 0.0,
  "failure_reason": "optional"
}

Rules:
- Do not invent tools or arguments.
- Prefer the minimal number of tools that yields a defensible action.
- If you use no write tools, status should be "skipped" unless execution failed.
- decision_confidence must be between 0.0 and 1.0.
- summary and decision_reason must be non-empty.|}
    agent_name identity_prompt goal context

let run_local ~agent_name ~identity_prompt ~goal ~context ~allow_post
    ?allowed_tools_override ?(allowed_tools_extra = []) () :
    (completion, string) result =
  let* model = worker_model_spec () in
  let prompt = build_prompt ~agent_name ~identity_prompt ~goal ~context in
  let worker_name =
    let digest =
      Digest.string (agent_name ^ goal ^ string_of_float (Time_compat.now ()))
      |> Digest.to_hex
    in
    sprintf "lodge-worker-%s-%s" agent_name (String.sub digest 0 8)
  in
  let allowed_tools =
    match allowed_tools_override with
    | Some names -> uniq names
    | None -> allowed_tools ~allow_post ~extra:allowed_tools_extra ()
  in
  Eio.Switch.run (fun sw ->
      match
        Local_agent_eio.run_worker ~sw ~base_path:(base_path ()) ~worker_name ~model
          ~room_config:None
          ~team_session_id:None ~role:(Some "lodge-worker") ~selection_note:None
          ~prompt ~allowed_tools ~timeout_sec:90 ()
      with
      | Error e -> Error e
      | Ok run_result ->
          let parsed = parse_completion_json run_result.output in
          let tool_names = run_result.tool_names in
          let tool_call_count = run_result.tool_call_count in
          let model_used = run_result.model_used in
          let output = run_result.output in
          let acted = acted_by_tools tool_names in
          let completion =
            match parsed with
            | Ok parsed ->
                {
                  parsed with
                  status =
                    (match parsed.status with
                    | Failed -> Failed
                    | Acted when acted -> Acted
                    | Acted -> Failed
                    | Skipped when acted -> Acted
                    | Skipped -> Skipped);
                  summary =
                    (match trim_opt (Some parsed.summary) with
                    | Some value -> value
                    | None -> default_summary tool_names);
                  decision_reason =
                    (match trim_opt (Some parsed.decision_reason) with
                    | Some value -> value
                    | None -> default_reason tool_names);
                  tool_call_count;
                  tool_names;
                  worker_name;
                  model_used;
                  output;
                  failure_reason =
                    (match parsed.status with
                    | Acted when not acted ->
                        Some "worker reported acted without any board write tool"
                    | _ -> parsed.failure_reason);
                }
            | Error parse_error ->
                {
                  status = if acted then Acted else Failed;
                  summary = default_summary tool_names;
                  decision_reason = default_reason tool_names;
                  decision_confidence = 0.0;
                  tool_call_count;
                  tool_names;
                  worker_name;
                  model_used;
                  output;
                  failure_reason = Some parse_error;
                }
          in
          Ok completion)
