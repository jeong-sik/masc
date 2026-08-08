(** Tests for Llm_provider.Metrics.Aggregating — per-provider counter accumulation.

    @since 0.188.0 *)

open Alcotest
open Llm_provider
module M = Metrics
module Agg = M.Aggregating

let test_aggregating_create_empty () =
  let agg = Agg.create () in
  let snap = Agg.snapshot agg in
  check int "empty snapshot" 0 (List.length snap)
;;

let test_aggregating_on_request_start () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_request_start ~model_id:"test-model";
  let snap = Agg.snapshot agg in
  check int "one entry" 1 (List.length snap);
  let entry = List.hd snap in
  check int "request_total" 1 entry.M.request_total;
  check string "provider" "unknown" entry.M.provider;
  check string "model_id" "test-model" entry.M.model_id
;;

let test_aggregating_on_retry () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_retry ~provider:"openai" ~model_id:"gpt-4" ~attempt:1;
  hooks.on_retry ~provider:"openai" ~model_id:"gpt-4" ~attempt:2;
  let snap = Agg.snapshot agg in
  check int "one entry" 1 (List.length snap);
  let entry = List.hd snap in
  check int "retry_total" 2 entry.M.retry_total;
  check string "provider" "openai" entry.M.provider;
  check string "model_id" "gpt-4" entry.M.model_id
;;

let test_aggregating_on_token_usage () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_token_usage
    ~provider:"anthropic"
    ~model_id:"claude-3"
    ~input_tokens:100
    ~output_tokens:50;
  hooks.on_token_usage
    ~provider:"anthropic"
    ~model_id:"claude-3"
    ~input_tokens:200
    ~output_tokens:75;
  let snap = Agg.snapshot agg in
  let entry = List.hd snap in
  check int "input_tokens_total" 300 entry.M.input_tokens_total;
  check int "output_tokens_total" 125 entry.M.output_tokens_total
;;

let test_aggregating_on_tool_calls () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_tool_calls ~provider:"ollama" ~model_id:"dashscope-3:8b" ~count:2;
  hooks.on_tool_calls ~provider:"ollama" ~model_id:"dashscope-3:8b" ~count:3;
  let snap = Agg.snapshot agg in
  let entry = List.hd snap in
  check int "tool_call_total" 5 entry.M.tool_call_total
;;

let test_aggregating_on_circuit_state () =
  let observed = ref None in
  let inner : M.t =
    { M.noop with
      on_circuit_state =
        (fun ~provider ~model_id ~provider_key ~state ->
          observed := Some (provider, model_id, provider_key, state))
    }
  in
  let agg = Agg.create ~inner () in
  let hooks = Agg.to_hooks agg in
  hooks.on_circuit_state
    ~provider:"openai"
    ~model_id:"gpt-4"
    ~provider_key:"gpt-4@https://api.openai.com"
    ~state:M.Circuit_open;
  (match !observed with
   | Some ("openai", "gpt-4", "gpt-4@https://api.openai.com", M.Circuit_open) -> ()
   | Some _ -> fail "unexpected circuit state callback"
   | None -> fail "missing circuit state callback");
  check int "state value" 1 (M.circuit_state_to_int M.Circuit_open);
  check string "state label" "open" (M.circuit_state_to_string M.Circuit_open)
;;

let test_aggregating_on_error () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_error ~model_id:"bad-model" ~error:"timeout";
  let snap = Agg.snapshot agg in
  let entry = List.hd snap in
  check int "error_total" 1 entry.M.error_total
;;

let test_aggregating_on_request_end_latency () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_request_start ~model_id:"lat-model";
  hooks.on_request_end ~model_id:"lat-model" ~latency_ms:(Some 100);
  hooks.on_request_end ~model_id:"lat-model" ~latency_ms:(Some 200);
  let snap = Agg.snapshot agg in
  let entry = List.hd snap in
  check int "latency_ms_sum" 300 entry.M.latency_ms_sum;
  check int "latency_ms_count" 2 entry.M.latency_ms_count
;;

let test_aggregating_unknown_latency_does_not_add_sample () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_request_start ~model_id:"lat-model";
  hooks.on_request_end ~model_id:"lat-model" ~latency_ms:None;
  let snap = Agg.snapshot agg in
  let entry = List.hd snap in
  check int "request_total" 1 entry.M.request_total;
  check int "latency_ms_sum" 0 entry.M.latency_ms_sum;
  check int "latency_ms_count" 0 entry.M.latency_ms_count
;;

let test_aggregating_on_streaming_latency () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_streaming_first_chunk ~provider:"anthropic" ~model_id:"claude" ~ttfrc_ms:12.5;
  hooks.on_streaming_chunk
    ~provider:"anthropic"
    ~model_id:"claude"
    ~chunk_index:1
    ~inter_chunk_ms:4.25;
  hooks.on_streaming_chunk
    ~provider:"anthropic"
    ~model_id:"claude"
    ~chunk_index:2
    ~inter_chunk_ms:5.75;
  let snap = Agg.snapshot agg in
  check int "one entry" 1 (List.length snap);
  let entry = List.hd snap in
  check string "provider" "anthropic" entry.M.provider;
  check string "model_id" "claude" entry.M.model_id;
  check (float 0.001) "ttfrc_ms_sum" 12.5 entry.M.ttfrc_ms_sum;
  check int "ttfrc_ms_count" 1 entry.M.ttfrc_ms_count;
  check (float 0.001) "inter_chunk_ms_sum" 10.0 entry.M.inter_chunk_ms_sum;
  check int "inter_chunk_ms_count" 2 entry.M.inter_chunk_ms_count
;;

let test_aggregating_reset () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_request_start ~model_id:"x";
  hooks.on_error ~model_id:"x" ~error:"err";
  Agg.reset agg;
  let snap = Agg.snapshot agg in
  check int "empty after reset" 0 (List.length snap)
;;

let test_aggregating_key () =
  check string "key format" "prov/model" (Agg.key ~provider:"prov" ~model_id:"model")
;;

let test_aggregating_multiple_providers () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_retry ~provider:"openai" ~model_id:"gpt-4" ~attempt:1;
  hooks.on_token_usage
    ~provider:"anthropic"
    ~model_id:"claude"
    ~input_tokens:50
    ~output_tokens:25;
  hooks.on_request_start ~model_id:"local";
  let snap = Agg.snapshot agg in
  check int "three entries" 3 (List.length snap)
;;

let test_provider_snapshot_to_yojson () =
  let snapshot : M.provider_snapshot =
    { provider = "openai"
    ; model_id = "gpt-4.1"
    ; request_total = 3
    ; error_total = 1
    ; retry_total = 2
    ; input_tokens_total = 123
    ; output_tokens_total = 45
    ; tool_call_total = 7
    ; latency_ms_sum = 900
    ; latency_ms_count = 3
    ; ttfrc_ms_sum = 15.5
    ; ttfrc_ms_count = 1
    ; inter_chunk_ms_sum = 8.25
    ; inter_chunk_ms_count = 2
    }
  in
  let json = M.provider_snapshot_to_yojson snapshot in
  match json with
  | `Assoc fields ->
    check
      (option string)
      "provider"
      (Some "openai")
      (List.assoc_opt "provider" fields |> Option.map Yojson.Safe.Util.to_string);
    check
      (option int)
      "request_total"
      (Some 3)
      (List.assoc_opt "request_total" fields |> Option.map Yojson.Safe.Util.to_int);
    check
      (option int)
      "tool_call_total"
      (Some 7)
      (List.assoc_opt "tool_call_total" fields |> Option.map Yojson.Safe.Util.to_int);
    check
      (option int)
      "latency_ms_count"
      (Some 3)
      (List.assoc_opt "latency_ms_count" fields |> Option.map Yojson.Safe.Util.to_int);
    check
      (option (float 0.001))
      "ttfrc_ms_sum"
      (Some 15.5)
      (List.assoc_opt "ttfrc_ms_sum" fields |> Option.map Yojson.Safe.Util.to_float);
    check
      (option int)
      "inter_chunk_ms_count"
      (Some 2)
      (List.assoc_opt "inter_chunk_ms_count" fields |> Option.map Yojson.Safe.Util.to_int)
  | _ -> fail "expected object"
;;

let test_provider_snapshots_to_yojson_is_stable () =
  let snapshots : M.provider_snapshot list =
    [ { provider = "z-provider"
      ; model_id = "z-model"
      ; request_total = 1
      ; error_total = 0
      ; retry_total = 0
      ; input_tokens_total = 0
      ; output_tokens_total = 0
      ; tool_call_total = 0
      ; latency_ms_sum = 0
      ; latency_ms_count = 0
      ; ttfrc_ms_sum = 0.0
      ; ttfrc_ms_count = 0
      ; inter_chunk_ms_sum = 0.0
      ; inter_chunk_ms_count = 0
      }
    ; { provider = "a-provider"
      ; model_id = "a-model"
      ; request_total = 2
      ; error_total = 0
      ; retry_total = 0
      ; input_tokens_total = 0
      ; output_tokens_total = 0
      ; tool_call_total = 0
      ; latency_ms_sum = 0
      ; latency_ms_count = 0
      ; ttfrc_ms_sum = 0.0
      ; ttfrc_ms_count = 0
      ; inter_chunk_ms_sum = 0.0
      ; inter_chunk_ms_count = 0
      }
    ]
  in
  match M.provider_snapshots_to_yojson snapshots with
  | `Assoc fields ->
    check
      (option int)
      "schema_version"
      (Some 2)
      (List.assoc_opt "schema_version" fields |> Option.map Yojson.Safe.Util.to_int);
    (match List.assoc_opt "providers" fields with
     | Some (`List (`Assoc first :: _)) ->
       check
         string
         "first provider"
         "a-provider"
         (List.assoc "provider" first |> Yojson.Safe.Util.to_string)
     | _ -> fail "expected providers list")
  | _ -> fail "expected object"
;;

let test_aggregating_save_snapshot_json () =
  let agg = Agg.create () in
  let hooks = Agg.to_hooks agg in
  hooks.on_retry ~provider:"openai" ~model_id:"gpt-4.1" ~attempt:1;
  hooks.on_token_usage
    ~provider:"openai"
    ~model_id:"gpt-4.1"
    ~input_tokens:10
    ~output_tokens:4;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oas-metrics-snapshot-%d" (Unix.getpid ()))
  in
  let path = Filename.concat dir "provider-snapshot.json" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with
       | Sys_error _ -> ());
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
       match Agg.save_snapshot_json agg ~path with
       | Error err -> failf "save_snapshot_json failed: %s" err
       | Ok () ->
         let json = Yojson.Safe.from_file path in
         (match json with
          | `Assoc fields ->
            (match List.assoc_opt "providers" fields with
             | Some (`List [ `Assoc provider ]) ->
               check
                 string
                 "provider"
                 "openai"
                 (List.assoc "provider" provider |> Yojson.Safe.Util.to_string);
               check
                 int
                 "retry_total"
                 1
                 (List.assoc "retry_total" provider |> Yojson.Safe.Util.to_int);
               check
                 int
                 "input_tokens_total"
                 10
                 (List.assoc "input_tokens_total" provider |> Yojson.Safe.Util.to_int)
             | _ -> fail "expected one provider")
          | _ -> fail "expected object"))
;;

let test_aggregating_inner_delegation () =
  let inner_request_start_called = ref false in
  let inner : M.t =
    { M.noop with
      on_request_start = (fun ~model_id:_ -> inner_request_start_called := true)
    }
  in
  let agg = Agg.create ~inner () in
  let hooks = Agg.to_hooks agg in
  hooks.on_request_start ~model_id:"test";
  check bool "inner on_request_start called" true !inner_request_start_called;
  let snap = Agg.snapshot agg in
  check int "aggregator also counted" 1 (List.length snap)
;;

let () =
  (* This suite intentionally stays outside [Eio_main.run]. Aggregating is part
     of the public exporter/test surface and must remain safe from ordinary
     synchronous callers. *)
  run
    "Metrics.Aggregating"
    [ "create", [ test_case "empty snapshot" `Quick test_aggregating_create_empty ]
    ; ( "counters"
      , [ test_case "on_request_start" `Quick test_aggregating_on_request_start
        ; test_case "on_retry" `Quick test_aggregating_on_retry
        ; test_case "on_token_usage" `Quick test_aggregating_on_token_usage
        ; test_case "on_tool_calls" `Quick test_aggregating_on_tool_calls
        ; test_case "on_circuit_state" `Quick test_aggregating_on_circuit_state
        ; test_case "on_error" `Quick test_aggregating_on_error
        ; test_case
            "on_request_end latency"
            `Quick
            test_aggregating_on_request_end_latency
        ; test_case
            "unknown request latency is not sampled"
            `Quick
            test_aggregating_unknown_latency_does_not_add_sample
        ; test_case
            "streaming latency callbacks"
            `Quick
            test_aggregating_on_streaming_latency
        ] )
    ; ( "lifecycle"
      , [ test_case "reset clears all" `Quick test_aggregating_reset
        ; test_case "key format" `Quick test_aggregating_key
        ; test_case "multiple providers" `Quick test_aggregating_multiple_providers
        ; test_case "snapshot to JSON" `Quick test_provider_snapshot_to_yojson
        ; test_case
            "snapshot list JSON is stable"
            `Quick
            test_provider_snapshots_to_yojson_is_stable
        ; test_case "save snapshot JSON" `Quick test_aggregating_save_snapshot_json
        ; test_case "inner delegation" `Quick test_aggregating_inner_delegation
        ] )
    ]
;;
