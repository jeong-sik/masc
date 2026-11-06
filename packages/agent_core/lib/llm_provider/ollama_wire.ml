(* See ollama_wire.mli for module rationale. *)

open Types

type ollama_tool_call_delta =
  { oll_tc_index : int
  ; oll_tc_id : string option
  ; oll_tc_name : string option
  ; oll_tc_arguments : Openai_wire.tool_call_arguments option
  }

type ollama_chunk =
  { oll_model : string
  ; oll_delta_content : string option
  ; oll_delta_thinking : string option
  ; oll_tool_calls : ollama_tool_call_delta list
  ; oll_done_reason : string option
  ; oll_is_done : bool
  ; oll_usage : api_usage option
  ; oll_timings : inference_timings option
  }

type ollama_ndjson_parse_result =
  | Ollama_chunk of ollama_chunk
  | Ollama_provider_error of
      { message : string
      ; error_type : string option
      ; raw : string
      }
  | Ollama_parse_failed of
      { reason : string
      ; raw : string
      }

let ollama_required_fields json =
  let open Yojson.Safe.Util in
  match
    json |> member "model" |> to_string_option, json |> member "done" |> to_bool_option
  with
  | Some model, Some is_done when not (Api_common.string_is_blank model) ->
    Some (model, is_done)
  | Some _, Some _ | None, _ | _, None -> None
;;

type ollama_line_shape =
  | Ollama_data_fields of string * bool
  | Ollama_provider_error_fields of
      { message : string
      ; error_type : string option
      }
  | Ollama_malformed_fields of string

let ollama_line_shape json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `String message -> Ollama_provider_error_fields { message; error_type = None }
  | `Assoc error_fields ->
    let error = `Assoc error_fields in
    let message =
      error |> member "message" |> to_string_option |> Option.value ~default:""
    in
    let error_type = error |> member "type" |> to_string_option in
    Ollama_provider_error_fields { message; error_type }
  | `Null ->
    (match ollama_required_fields json with
     | Some (model, is_done) -> Ollama_data_fields (model, is_done)
     | None -> Ollama_malformed_fields "ollama_ndjson_missing_required_field")
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ ->
    Ollama_malformed_fields "ollama_ndjson_error_field_type"
;;

let parse_ollama_ndjson_chunk data_str : ollama_ndjson_parse_result =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string data_str in
    match ollama_line_shape json with
    | Ollama_provider_error_fields { message; error_type } ->
      Ollama_provider_error { message; error_type; raw = data_str }
    | Ollama_malformed_fields reason -> Ollama_parse_failed { reason; raw = data_str }
    | Ollama_data_fields (oll_model, oll_is_done) ->
      let oll_done_reason = json |> member "done_reason" |> to_string_option in
      let message = json |> member "message" in
      let oll_delta_content =
        match message with
        | `Assoc _ ->
          let s = message |> member "content" |> to_string_option in
          (match s with
           | Some "" -> None
           | other -> other)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
      in
      let oll_delta_thinking =
        match message with
        | `Assoc _ ->
          let s = message |> member "thinking" |> to_string_option in
          (match s with
           | Some "" -> None
           | other -> other)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
      in
      let oll_tool_calls =
        match message with
        | `Assoc _ ->
          (match message |> member "tool_calls" with
           | `List items ->
             List.mapi
               (fun idx tc ->
                  let func = tc |> member "function" in
                  let oll_tc_name = func |> member "name" |> to_string_option in
                  let oll_tc_id = tc |> member "id" |> to_string_option in
                  let oll_tc_arguments =
                    match func |> member "arguments" with
                    | `Null -> None
                    | (`Assoc _ | `List _) as v ->
                      Some (Openai_wire.Args_complete (Yojson.Safe.to_string v))
                    | `String s -> Some (Openai_wire.Args_fragment s)
                    | other -> Some (Openai_wire.Args_complete (Yojson.Safe.to_string other))
                  in
                  { oll_tc_index = idx; oll_tc_id; oll_tc_name; oll_tc_arguments })
               items
           | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> [])
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []
      in
      (* Token-count usage. Ollama only emits these on the done chunk.
         When both counts are zero we return None, matching the
         non-streaming path in [Backend_ollama.parse_ollama_response]
         so that a downstream consumer's usage-trust classification sees
         [Usage_missing] instead of [zero_token_usage_reported]. *)
      let oll_usage =
        let input = json |> member "prompt_eval_count" |> to_int_option in
        let output = json |> member "eval_count" |> to_int_option in
        match input, output with
        | None, None -> None
        | Some _, None | None, Some _ | Some _, Some _ ->
          let input_tokens = Option.value ~default:0 input in
          let output_tokens = Option.value ~default:0 output in
          if input_tokens = 0 && output_tokens = 0
          then None
          else
            Some
              { input_tokens
              ; output_tokens
              ; cache_creation_input_tokens = 0
              ; cache_read_input_tokens = 0
              ; cost_usd = None
              }
      in
      (* inference_timings: same wire-format the non-streaming
         Backend_ollama.parse_ollama_response builds, so downstream
         (record_llm_tok_s_metrics) is byte-identical between the two
         paths. Durations are nanoseconds on the wire; convert to ms
         and tok/s here. *)
      let oll_timings =
        let prompt_n = json |> member "prompt_eval_count" |> to_int_option in
        let prompt_ns = json |> member "prompt_eval_duration" |> to_int_option in
        let predicted_n = json |> member "eval_count" |> to_int_option in
        let predicted_ns = json |> member "eval_duration" |> to_int_option in
        let any_set =
          Option.is_some prompt_n
          || Option.is_some prompt_ns
          || Option.is_some predicted_n
          || Option.is_some predicted_ns
        in
        if not any_set
        then None
        else (
          let ms_of_ns ns_opt = Option.map (fun ns -> float_of_int ns /. 1e6) ns_opt in
          let per_second n_opt ns_opt =
            match n_opt, ns_opt with
            | Some n, Some ns when ns > 0 ->
              Some (float_of_int n /. (float_of_int ns /. 1e9))
            | Some _, Some _ | Some _, None | None, Some _ | None, None -> None
          in
          Some
            { prompt_n
            ; prompt_ms = ms_of_ns prompt_ns
            ; prompt_per_second = per_second prompt_n prompt_ns
            ; predicted_n
            ; predicted_ms = ms_of_ns predicted_ns
            ; predicted_per_second = per_second predicted_n predicted_ns
            ; cache_n = None
            })
      in
      Ollama_chunk
        { oll_model
        ; oll_delta_content
        ; oll_delta_thinking
        ; oll_tool_calls
        ; oll_done_reason
        ; oll_is_done
        ; oll_usage
        ; oll_timings
        }
  with
  | Yojson.Json_error message ->
    Ollama_parse_failed { reason = "json_error: " ^ message; raw = data_str }
  | Type_error (message, _) ->
    Ollama_parse_failed { reason = "type_error: " ^ message; raw = data_str }
;;

[@@@coverage off]
(* ── parse_ollama_ndjson_chunk tests ──────────────────────── *)

let%test "parse_ollama_ndjson_chunk: content delta line" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":"hi"},"done":false}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    c.oll_model = "qwen3:8b"
    && c.oll_delta_content = Some "hi"
    && c.oll_delta_thinking = None
    && c.oll_tool_calls = []
    && (not c.oll_is_done)
    && c.oll_usage = None
    && c.oll_timings = None
;;

let%test "parse_ollama_ndjson_chunk: done line carries timings + usage" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},
       "done_reason":"stop","done":true,
       "prompt_eval_count":15,"prompt_eval_duration":300000000,
       "eval_count":50,"eval_duration":1000000000}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    c.oll_is_done
    && c.oll_done_reason = Some "stop"
    && (match c.oll_usage with
        | Some u -> u.input_tokens = 15 && u.output_tokens = 50
        | None -> false)
    &&
      (match c.oll_timings with
      | Some t ->
        t.predicted_n = Some 50
        && t.prompt_n = Some 15
        && (match t.predicted_per_second with
            | Some v -> abs_float (v -. 50.0) < 0.001
            | None -> false)
        &&
          (match t.prompt_per_second with
          | Some v -> abs_float (v -. 50.0) < 0.001
          | None -> false)
      | None -> false)
;;

let%test "parse_ollama_ndjson_chunk: zero eval_duration → per_second None" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},
       "done":true,"eval_count":10,"eval_duration":0}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_chunk c ->
    (match c.oll_timings with
     | Some t -> t.predicted_n = Some 10 && t.predicted_per_second = None
     | None -> false)
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
;;

let%test "parse_ollama_ndjson_chunk: tool_calls fully formed in done line" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":"",
       "tool_calls":[{"function":{"name":"foo","arguments":{"x":1}}}]},
       "done":true,"done_reason":"tool_calls"}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
  | Ollama_chunk c ->
    (match c.oll_tool_calls with
     | [ tc ] ->
       tc.oll_tc_name = Some "foo"
       &&
         (match tc.oll_tc_arguments with
         | Some (Openai_wire.Args_fragment args | Openai_wire.Args_complete args) ->
           let json = Yojson.Safe.from_string args in
           json |> Yojson.Safe.Util.member "x" |> Yojson.Safe.Util.to_int = 1
         | None -> false)
     | unexpected_tool_calls ->
       let (_ : ollama_tool_call_delta list) = unexpected_tool_calls in
       false)
;;

let%test "parse_ollama_ndjson_chunk: malformed json is explicit" =
  match parse_ollama_ndjson_chunk "{not valid" with
  | Ollama_parse_failed _ -> true
  | Ollama_chunk _ | Ollama_provider_error _ -> false
;;

let%test "parse_ollama_ndjson_chunk: provider error is explicit" =
  match parse_ollama_ndjson_chunk {|{"error":"model failed"}|} with
  | Ollama_provider_error { message; error_type = None; raw } ->
    message = "model failed" && raw = {|{"error":"model failed"}|}
  | Ollama_chunk _ | Ollama_parse_failed _ -> false
  | Ollama_provider_error { error_type = Some _; _ } -> false
;;

let%test "parse_ollama_ndjson_chunk: missing provider message does not copy raw" =
  let raw = {|{"error":{"type":"server_error","detail":"opaque"}}|} in
  match parse_ollama_ndjson_chunk raw with
  | Ollama_provider_error { message; error_type = Some "server_error"; raw = r } ->
    message = "" && r = raw
  | Ollama_chunk _ | Ollama_parse_failed _ -> false
  | Ollama_provider_error { error_type = None; _ } -> false
  | Ollama_provider_error { error_type = Some _; _ } -> false
;;

let%test "parse_ollama_ndjson_chunk: done with zero token counts keeps chunk" =
  let line =
    {|{"model":"qwen3:8b","message":{"role":"assistant","content":""},
       "done_reason":"stop","done":true,
       "prompt_eval_count":0,"eval_count":0}|}
  in
  match parse_ollama_ndjson_chunk line with
  | Ollama_chunk c -> c.oll_is_done && c.oll_usage = None
  | Ollama_parse_failed _ | Ollama_provider_error _ -> false
;;
