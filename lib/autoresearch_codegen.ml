(** Autoresearch_codegen — LLM-based code change generation.

    Builds prompts, parses MODEL responses as a strict JSON object, and
    invokes the cascade for code generation.

    @since 2.80.0 *)

include Autoresearch_types

(** Build prompt for MODEL code change. Exported for testing. *)
let build_code_change_prompt ~goal ~baseline ~lower_is_better ~history ~insights
    ~file_content ~target_file =
  let recent = List.filteri (fun i _ -> i < 5) history in
  let history_lines = List.map (fun (r : cycle_record) ->
    Printf.sprintf "  Cycle %d: %s -> delta=%.4f (%s)"
      r.cycle r.hypothesis r.delta (Autoresearch_serde.decision_to_string r.decision)
  ) recent in
  let insight_lines = List.map (fun s -> "  - " ^ s) insights in
  let polarity = if lower_is_better then "lower is better" else "higher is better" in
  String.concat "\n" ([
    "You are an autonomous research assistant optimizing code.";
    Printf.sprintf "Goal: %s" goal;
    Printf.sprintf "Current baseline score: %.4f (%s)" baseline polarity;
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
    "Reply with exactly one valid JSON object and nothing else.";
    "Do not wrap the JSON in markdown or code fences.";
    "The JSON object must contain:";
    "1. \"hypothesis\": a one-line description of your change";
    "2. \"modified_code\": the COMPLETE modified file";
    "";
    "Example format:";
    {|{"hypothesis":"Increase batch size from 32 to 64 for better throughput","modified_code":"... complete file content ..."}|};
  ])

(** Strip leading/trailing whitespace-only lines from generated code. *)
let normalize_modified_code code =
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

let parse_required_string_field ~field json =
  match Safe_ops.json_member_opt field json with
  | None ->
    Result.error (Printf.sprintf "Missing \"%s\" field in MODEL response" field)
  | Some (`String value) ->
    let trimmed = String.trim value in
    if trimmed = "" then
      Result.error (Printf.sprintf "Empty \"%s\" field in MODEL response" field)
    else
      Result.ok value
  | Some _ ->
    Result.error (Printf.sprintf "\"%s\" field must be a string in MODEL response" field)

(** Parse MODEL response expected to contain a JSON object with hypothesis and
    modified_code string fields. Uses Lenient_json for deterministic recovery
    (strip fences, unwrap double-stringify, trailing commas, close brackets).
    Returns Ok (hypothesis, modified_code) or Error reason. *)
let parse_model_code_response response =
  let trimmed_response = String.trim response in
  if trimmed_response = "" then
    Result.error "MODEL returned empty response"
  else
    (* Lenient_json.parse applies deterministic recovery transforms:
       strip markdown fences, unwrap double-stringify, trailing commas,
       keyword completion, bracket closure — then standard parse.
       Falls back to {raw: string} if all transforms fail. *)
    match Llm_provider.Lenient_json.parse trimmed_response with
    | `Assoc [("raw", `String raw)] ->
      (* Lenient_json fallback: all recovery transforms failed, raw string returned *)
      let preview =
        raw
        |> String.split_on_char '\n'
        |> String.concat " "
        |> String.trim
        |> fun normalized ->
        String_util.utf8_safe ~max_bytes:83 ~suffix:"..." normalized |> String_util.to_string
      in
      Result.error (Printf.sprintf "MODEL response is not valid JSON after lenient recovery: %s" preview)
    | `Assoc _ as json ->
      (match parse_required_string_field ~field:"hypothesis" json with
      | Error _ as e -> e
      | Ok hypothesis ->
        match parse_required_string_field ~field:"modified_code" json with
        | Error _ as e -> e
        | Ok code ->
          let normalized_code = normalize_modified_code code in
          if normalized_code = "" then
            Result.error "Empty \"modified_code\" field in MODEL response"
          else
            Result.ok (String.trim hypothesis, normalized_code))
    | _ ->
      Result.error "MODEL response must be a JSON object"

let has_background_capacity () =
  let cascade_name =
    Keeper_cascade_profile.cascade_name_for_use
      Keeper_cascade_profile.Autoresearch
  in
  match Eio_context.get_switch_opt (), Eio_context.get_net_opt () with
  | Some sw, Some net -> (
      try
        let capacity =
          Cascade_config.local_capacity_for_selections ~sw ~net
            [ cascade_name ]
        in
        not
          (capacity.all_discovered && capacity.endpoints_found > 0
           && capacity.process_available <= 0)
      with
      | Eio.Cancel.Cancelled _ as ex -> raise ex
      | ex ->
        Log.Autoresearch.warn "capacity check failed: %s" (Printexc.to_string ex);
        false)
  | _ ->
    Log.Autoresearch.warn "capacity check skipped: no Eio switch/net context available (returning false)";
    false

(** Generate code change via the profile selected by [routes.autoresearch].
    Returns Ok (hypothesis, new_code) or Error reason. *)
let generate_code_change ~goal ~baseline ~lower_is_better ~history ~insights
    ~target_file ~file_content =
  if not (has_background_capacity ()) then begin
    Log.Autoresearch.info "backoff: local slots saturated, skipping cycle";
    Result.error "autoresearch: local slots saturated, skipping cycle"
  end else
  let prompt = build_code_change_prompt ~goal ~baseline ~lower_is_better ~history ~insights
    ~file_content ~target_file in
  let cascade_name =
    Keeper_cascade_profile.cascade_name_for_use
      Keeper_cascade_profile.Autoresearch
  in
  let inference_cascade_name = Keeper_cascade_profile.Runtime_name cascade_name in
  match
    Masc_oas_bridge.run_with_caller
      ~caller:Env_config_oas_bridge.Autoresearch_codegen (fun () ->
      Keeper_turn_driver.run_named ~cascade_name
        ~goal:prompt ~max_turns:1
        ~temperature:(Cascade_inference.resolve_temperature
          ~cascade_name:inference_cascade_name ~fallback:(fun () -> 0.7))
        ~max_tokens:(Cascade_inference.resolve_max_tokens
          ~cascade_name:inference_cascade_name ~fallback:(fun () -> 4096))
        ~approval:Approval_callbacks.auto_approve
        ()
    )
  with
  | Error e -> Result.error (Printf.sprintf "MODEL call failed: %s" (Agent_sdk.Error.to_string e))
  | Ok result -> parse_model_code_response (Agent_sdk_response.text_of_response result.Keeper_turn_driver.response)
