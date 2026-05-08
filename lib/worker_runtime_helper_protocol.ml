type error_kind =
  | Spec_parse
  | Runtime
  | Timeout
  | Internal

type error_payload = {
  message : string;
  kind : error_kind;
}

let error_kind_to_string = function
  | Spec_parse -> "spec_parse"
  | Runtime -> "runtime"
  | Timeout -> "timeout"
  | Internal -> "internal"

let error_kind_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "spec_parse" -> Some Spec_parse
  | "runtime" -> Some Runtime
  | "timeout" -> Some Timeout
  | "internal" -> Some Internal
  | _ -> None

let option_to_yojson to_json = function
  | Some value -> to_json value
  | None -> `Null

open Result.Syntax

let int_option_of_yojson = function
  | `Null -> Ok None
  | `Int value -> Ok (Some value)
  | `Intlit value -> (
      match int_of_string_opt value with Some v -> Ok (Some v) | None -> Error "invalid int option in worker helper payload")
  | _ -> Error "invalid int option in worker helper payload"

let float_option_of_yojson = function
  | `Null -> Ok None
  | `Float value -> Ok (Some value)
  | `Int value -> Ok (Some (float_of_int value))
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some f -> Ok (Some f)
      | None -> Error "invalid float option in worker helper payload")
  | `String value -> (
      match float_of_string_opt value with
      | Some f -> Ok (Some f)
      | None -> Error "invalid float option in worker helper payload")
  | _ -> Error "invalid float option in worker helper payload"

let string_list_of_yojson = function
  | `List values ->
      List.fold_right
        (fun value acc ->
          match (value, acc) with
          | `String s, Ok rest -> Ok (s :: rest)
          | _, Ok _ -> Error "invalid string list in worker helper payload"
          | _, Error msg -> Error msg)
        values (Ok [])
  | _ -> Error "invalid string list in worker helper payload"

let api_response_to_yojson =
  option_to_yojson Llm_provider.Cache.response_to_json

let api_response_of_yojson = function
  | `Null -> Ok None
  | json -> (
      match Llm_provider.Cache.response_of_json json with
      | Some response -> Ok (Some response)
      | None -> Error "invalid api_response in worker helper payload")

let proof_to_yojson =
  option_to_yojson Masc_mcp_cdal_runtime.Cdal_proof.to_json

let proof_of_yojson = function
  | `Null -> Ok None
  | json -> (
      match Masc_mcp_cdal_runtime.Cdal_proof.of_json json with
      | Ok proof -> Ok (Some proof)
      | Error msg -> Error ("invalid proof in worker helper payload: " ^ msg))

let run_result_to_yojson (run_result : Worker_container_types.run_result) =
  `Assoc
    [
      ("output", `String run_result.output);
      ("model_used", `String run_result.model_used);
      ("input_tokens", option_to_yojson (fun v -> `Int v) run_result.input_tokens);
      ("output_tokens", option_to_yojson (fun v -> `Int v) run_result.output_tokens);
      ("cost_usd", option_to_yojson (fun v -> `Float v) run_result.cost_usd);
      ("tool_call_count", `Int run_result.tool_call_count);
      ("tool_names", `List (List.map (fun name -> `String name) run_result.tool_names));
      ("session_id", `String run_result.session_id);
      ( "raw_trace_run",
        option_to_yojson Agent_sdk.Raw_trace.run_ref_to_yojson run_result.raw_trace_run );
      ("api_response", api_response_to_yojson run_result.api_response);
      ("proof", proof_to_yojson run_result.proof);
    ]

let run_result_of_yojson (json : Yojson.Safe.t) :
    (Worker_container_types.run_result, string) result =
  let open Yojson.Safe.Util in
  try
    let output = json |> member "output" |> to_string in
    let model_used = json |> member "model_used" |> to_string in
    let tool_call_count = json |> member "tool_call_count" |> to_int in
    let session_id = json |> member "session_id" |> to_string in
    let* input_tokens = int_option_of_yojson (json |> member "input_tokens") in
    let* output_tokens =
      int_option_of_yojson (json |> member "output_tokens")
    in
    let* cost_usd = float_option_of_yojson (json |> member "cost_usd") in
    let* tool_names = string_list_of_yojson (json |> member "tool_names") in
    let* raw_trace_run =
      match json |> member "raw_trace_run" with
      | `Null -> Ok None
      | value -> (
          match Agent_sdk.Raw_trace.run_ref_of_yojson value with
          | Ok run_ref -> Ok (Some run_ref)
          | Error msg ->
              Error ("invalid raw_trace_run in worker helper payload: " ^ msg))
    in
    let* api_response = api_response_of_yojson (json |> member "api_response") in
    let* proof = proof_of_yojson (json |> member "proof") in
    let run_result : Worker_container_types.run_result = {
      output;
      model_used;
      input_tokens;
      output_tokens;
      cost_usd;
      tool_call_count;
      tool_names;
      session_id;
      raw_trace_run;
      api_response;
      proof;
    } in
    Ok run_result
  with
  | Yojson.Json_error msg -> Error ("invalid worker helper run_result JSON: " ^ msg)
  | Type_error (msg, _) -> Error ("invalid worker helper run_result JSON: " ^ msg)
  | Failure msg -> Error msg

let success_json (run_result : Worker_container_types.run_result) =
  `Assoc [ ("ok", run_result_to_yojson run_result) ]

let error_json (payload : error_payload) =
  `Assoc
    [
      ( "error",
        `Assoc
          [
            ("message", `String payload.message);
            ("kind", `String (error_kind_to_string payload.kind));
          ] );
    ]

let parse_stdout (stdout : string) :
    ((Worker_container_types.run_result, error_payload) result, string) result =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string stdout in
    match json |> member "ok" with
    | `Assoc _ as payload -> (
        match run_result_of_yojson payload with
        | Ok run_result -> Ok (Ok run_result)
        | Error msg -> Error msg)
    | _ -> (
        match json |> member "error" with
        | `Assoc fields ->
            let message =
              match List.assoc_opt "message" fields with
              | Some (`String value) -> value
              | _ -> "worker helper error"
            in
            (* Issue #8705: log unknown wire-string kinds so subprocess
               version skew is operator-visible. Missing key still
               silently defaults to [Internal] - that case is the
               documented contract. *)
            let kind =
              match List.assoc_opt "kind" fields with
              | Some (`String value) -> (
                  match error_kind_of_string value with
                  | Some kind -> kind
                  | None ->
                      Log.Misc.warn
                        "worker_runtime_helper: unknown error_kind %S → Internal fallback (#8705)"
                        value;
                      Internal)
              | _ -> Internal
            in
            Ok (Error { message; kind })
        | _ -> Error "worker helper stdout did not contain ok or error")
  with
  | Failure msg -> Error msg
  | Yojson.Json_error msg -> Error ("invalid worker helper JSON: " ^ msg)
