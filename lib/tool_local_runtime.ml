(** Tool_local_runtime -- local model runtime management and benchmarking tools.

    Facade module that re-exports sub-modules and provides MCP dispatch/schemas.
    Implementation is split across:
    - Tool_local_runtime_core   : types, helpers, process discovery, model fetching
    - Tool_local_runtime_http   : HTTP helpers (curl wrappers, JSON member access)
    - Tool_local_runtime_verify : runtime contract verification
    - Tool_local_runtime_bench  : concurrency benchmark
    - Tool_local_runtime_status : runtime pool status reporting
    - Tool_local_runtime_probe  : native Ollama timing/KV inference probe *)

open Types

(* Re-export core types and helpers for backward compatibility *)
include Tool_local_runtime_core

(* Re-export sub-module public values used by external callers *)
let runtime_status_json = Tool_local_runtime_status.runtime_status_json
let runtime_verify_json = Tool_local_runtime_verify.runtime_verify_json
let runtime_ollama_probe_json = Tool_local_runtime_probe.runtime_ollama_probe_json
let run_bench = Tool_local_runtime_bench.run_bench
let provider_health_reachable = Tool_local_runtime_verify.provider_health_reachable
let classify_runtime_blocker = Tool_local_runtime_verify.classify_runtime_blocker
let ollama_loaded_models_of_ps_json = Tool_local_runtime_probe.ollama_loaded_models_of_ps_json
let ollama_probe_run_of_generate_json = Tool_local_runtime_probe.ollama_probe_run_of_generate_json
let kv_cache_assessment_json = Tool_local_runtime_probe.kv_cache_assessment_json

let handle_models _ctx : result =
  match fetch_models () with
  | Error msg -> (false, json_error msg)
  | Ok (url, models) ->
      ( true,
        json_ok
          [
            ( "result",
              `Assoc
                [
                  ("server_url", `String Env_config.Llama.server_url);
                  ("endpoint", `String url);
                  ("source", `String "llama.cpp /v1/models");
                  ("models", `List (List.map (fun m -> `String m) models));
                  ("model_count", `Int (List.length models));
                ] );
          ] )

let handle_runtime_status _ctx args : result =
  let include_models =
    match Yojson.Safe.Util.member "include_models" args with
    | `Bool flag -> flag
    | _ -> true
  in
  (true, json_ok [ ("result", runtime_status_json ~include_models ()) ])

let handle_runtime_verify _ctx args : result =
  let open Yojson.Safe.Util in
  let runtime_pool = member "runtime_pool" args |> to_string_option in
  let expected_model = member "expected_model" args |> to_string_option in
  let expected_slots =
    match member "expected_slots" args with
    | `Int value -> Some (max 1 value)
    | `Intlit value -> parse_int_opt value
    | _ -> None
  in
  let expected_ctx =
    match member "expected_ctx" args with
    | `Int value -> Some (max 1 value)
    | `Intlit value -> parse_int_opt value
    | _ -> None
  in
  ( true,
    json_ok
      [
        ( "result",
          runtime_verify_json ?runtime_pool ?expected_slots ?expected_ctx
            ?expected_model () );
      ] )

let handle_runtime_bench _ctx args : result =
  let open Yojson.Safe.Util in
  let model_id = member "model" args |> to_string_option in
  let runtime_pool = member "runtime_pool" args |> to_string_option in
  let parallelism =
    match member "parallelism" args with
    | `Int value -> max 1 (min 128 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 1 (min 128 parsed)
        | None -> 8)
    | _ -> 8
  in
  let rounds =
    match member "rounds" args with
    | `Int value -> max 1 (min 8 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 1 (min 8 parsed)
        | None -> 1)
    | _ -> 1
  in
  let max_tokens =
    match member "max_tokens" args with
    | `Int value -> max 1 (min 128 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 1 (min 128 parsed)
        | None -> 16)
    | _ -> 16
  in
  let timeout_sec =
    match member "timeout_sec" args with
    | `Int value -> max 3 (min 120 value)
    | `Intlit value -> (
        match parse_int_opt value with
        | Some parsed -> max 3 (min 120 parsed)
        | None -> 8)
    | _ -> 8
  in
  let prompt =
    match member "prompt" args with
    | `String value when String.trim value <> "" -> String.trim value
    | _ -> "Reply with exactly one short word: ready"
  in
  match
    run_bench ?model_id ?runtime_pool ~parallelism ~rounds ~prompt
      ~max_tokens ~timeout_sec ()
  with
  | Ok json -> (true, json_ok [ ("result", json) ])
  | Error err -> (false, json_error err)

let handle_runtime_ollama_probe _ctx args : result =
  let open Yojson.Safe.Util in
  let server_url = member "server_url" args |> to_string_option in
  let model = member "model" args |> to_string_option in
  let prompt = member "prompt" args |> to_string_option in
  let keep_alive = member "keep_alive" args |> to_string_option in
  let probe_runs =
    match member "probe_runs" args with
    | `Int value -> value
    | `Intlit value -> Option.value ~default:2 (parse_int_opt value)
    | _ -> 2
  in
  let max_tokens =
    match member "max_tokens" args with
    | `Int value -> value
    | `Intlit value -> Option.value ~default:16 (parse_int_opt value)
    | _ -> 16
  in
  let timeout_sec =
    match member "timeout_sec" args with
    | `Int value -> value
    | `Intlit value -> Option.value ~default:45 (parse_int_opt value)
    | _ -> 45
  in
  ( true,
    json_ok
      [
        ( "result",
          runtime_ollama_probe_json ?server_url ?model ?prompt ?keep_alive
            ~probe_runs ~max_tokens ~timeout_sec () );
      ] )

let dispatch ctx ~name ~args : result option =
  match name with
  (* Canonical names *)
  | "masc_runtime_verify" ->
      Some (handle_runtime_verify ctx args)
  | "masc_runtime_ollama_probe" ->
      Some (handle_runtime_ollama_probe ctx args)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_runtime_verify";
      description =
        "Strictly verify the active provider/runtime contract used for swarm and benchmark runs. Returns reachability, chat-completions contract status, model match, slots, ctx, configured capacity, active slots, and blocker codes such as provider_unreachable, provider_model_mismatch, slot_count_insufficient, ctx_mismatch, or chat_contract_incompatible.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
                  ("expected_model", `Assoc [ ("type", `String "string") ]);
                  ("expected_slots", `Assoc [ ("type", `String "integer") ]);
                  ("expected_ctx", `Assoc [ ("type", `String "integer") ]);
                ] );
          ];
    };
    {
      name = "masc_runtime_ollama_probe";
      description =
        "Probe native Ollama timing behavior with repeated /api/generate calls. Returns loaded models from /api/ps, per-run load/prompt-eval/generation timings, tok/sec estimates, and a timing-based repeated-prefix reuse inference. This does not expose direct KV occupancy or hit-rate.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("server_url", `Assoc [ ("type", `String "string") ]);
                  ("model", `Assoc [ ("type", `String "string") ]);
                  ("prompt", `Assoc [ ("type", `String "string") ]);
                  ("keep_alive", `Assoc [ ("type", `String "string") ]);
                  ("probe_runs", `Assoc [ ("type", `String "integer") ]);
                  ("max_tokens", `Assoc [ ("type", `String "integer") ]);
                  ("timeout_sec", `Assoc [ ("type", `String "integer") ]);
                ] );
          ];
    };
  ]

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_local_runtime
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
