(** Coverage tests for chain_utils, chain_iteration, chain_trace_types, chain_conversation *)

open Alcotest
open Masc_mcp

(* ═══ Chain_utils ═══ *)

let test_list_nth_opt_valid () =
  check (option int) "idx 0" (Some 10) (Chain_utils.list_nth_opt [10;20;30] 0);
  check (option int) "idx 2" (Some 30) (Chain_utils.list_nth_opt [10;20;30] 2)

let test_list_nth_opt_oob () =
  check (option int) "neg" None (Chain_utils.list_nth_opt [1;2] (-1));
  check (option int) "too big" None (Chain_utils.list_nth_opt [1;2] 5);
  check (option int) "empty" None (Chain_utils.list_nth_opt [] 0)

let test_list_hd_opt () =
  check (option int) "some" (Some 1) (Chain_utils.list_hd_opt [1;2]);
  check (option int) "none" None (Chain_utils.list_hd_opt [])

let test_list_tl_safe () =
  check (list int) "tail" [2;3] (Chain_utils.list_tl_safe [1;2;3]);
  check (list int) "empty" [] (Chain_utils.list_tl_safe [])

let test_list_uncons () =
  check (option (pair int (list int))) "some" (Some (1,[2;3])) (Chain_utils.list_uncons [1;2;3]);
  check (option (pair int (list int))) "none" None (Chain_utils.list_uncons [])

let test_list_last_opt () =
  check (option int) "some" (Some 3) (Chain_utils.list_last_opt [1;2;3]);
  check (option int) "single" (Some 1) (Chain_utils.list_last_opt [1]);
  check (option int) "none" None (Chain_utils.list_last_opt [])

let test_starts_with () =
  check bool "yes" true (Chain_utils.starts_with ~prefix:"foo" "foobar");
  check bool "no" false (Chain_utils.starts_with ~prefix:"baz" "foobar");
  check bool "empty prefix" true (Chain_utils.starts_with ~prefix:"" "abc")

let test_ends_with () =
  check bool "yes" true (Chain_utils.ends_with ~suffix:"bar" "foobar");
  check bool "no" false (Chain_utils.ends_with ~suffix:"baz" "foobar");
  check bool "empty suffix" true (Chain_utils.ends_with ~suffix:"" "abc")

let test_string_sub_opt () =
  check (option string) "ok" (Some "oba") (Chain_utils.string_sub_opt "foobar" 2 3);
  check (option string) "oob" None (Chain_utils.string_sub_opt "foo" 2 5)

let test_truncate () =
  check string "short" "hi" (Chain_utils.truncate_with_ellipsis ~max_len:10 "hi");
  let result = Chain_utils.truncate_with_ellipsis ~max_len:8 "abcdefghijklmno" in
  check bool "truncated has ellipsis" true (Chain_utils.ends_with ~suffix:"..." result);
  check bool "truncated is shorter" true (String.length result <= 11)

let test_strip_prefix () =
  check string "match" "bar" (Chain_utils.strip_prefix ~prefix:"foo" "foobar");
  check string "no match" "foobar" (Chain_utils.strip_prefix ~prefix:"baz" "foobar")

let test_strip_suffix () =
  check string "match" "foo" (Chain_utils.strip_suffix ~suffix:"bar" "foobar");
  check string "no match" "foobar" (Chain_utils.strip_suffix ~suffix:"baz" "foobar")

let test_is_empty_response () =
  check bool "empty" true (Chain_utils.is_empty_response "");
  check bool "whitespace" true (Chain_utils.is_empty_response "   \n\t  ");
  check bool "content" false (Chain_utils.is_empty_response "hello")

let test_is_complex_prompt () =
  check bool "short" false (Chain_utils.is_complex_prompt "do x");
  let long = String.make 1000 'a' in
  check bool "long" true (Chain_utils.is_complex_prompt long)

let test_is_glm_model () =
  check bool "glm" true (Chain_utils.is_glm_model "glm:auto");
  check bool "claude" false (Chain_utils.is_glm_model "claude:opus")

let test_string_contains () =
  check bool "yes" true (Chain_utils.string_contains ~substring:"bar" "foobar");
  check bool "no" false (Chain_utils.string_contains ~substring:"baz" "foobar");
  check bool "empty" true (Chain_utils.string_contains ~substring:"" "anything")

(* ═══ Chain_iteration ═══ *)

let test_substitute_none () =
  check string "no ctx" "hello" (Chain_iteration.substitute_vars "hello" None)

let test_substitute_basic () =
  let ctx = { Chain_iteration.iteration = 3; max_iterations = 10; progress = 0.5;
              last_value = 42.0; goal_value = 100.0; strategy = Some "greedy" } in
  let result = Chain_iteration.substitute_vars "iter={{iteration}} max={{max_iterations}} prog={{progress}}" (Some ctx) in
  check bool "has iter" true (String.length result > 0);
  check bool "contains 3" true (try let _ = Str.search_forward (Str.regexp_string "3") result 0 in true with Not_found -> false)

let test_substitute_strategy () =
  let ctx = { Chain_iteration.iteration = 1; max_iterations = 5; progress = 0.0;
              last_value = 0.0; goal_value = 1.0; strategy = None } in
  let result = Chain_iteration.substitute_vars "s={{strategy}}" (Some ctx) in
  check bool "default strategy" true (try let _ = Str.search_forward (Str.regexp_string "default") result 0 in true with Not_found -> false)

let test_substitute_linear () =
  let ctx = { Chain_iteration.iteration = 5; max_iterations = 10; progress = 0.5;
              last_value = 50.0; goal_value = 100.0; strategy = None } in
  let result = Chain_iteration.substitute_vars "temp={{linear:0.1,0.9}}" (Some ctx) in
  check bool "substituted" true (not (try let _ = Str.search_forward (Str.regexp_string "{{linear") result 0 in true with Not_found -> false))

let test_substitute_step () =
  let ctx = { Chain_iteration.iteration = 2; max_iterations = 5; progress = 0.4;
              last_value = 40.0; goal_value = 100.0; strategy = None } in
  let result = Chain_iteration.substitute_vars "v={{step:low,med,high}}" (Some ctx) in
  check bool "substituted" true (not (try let _ = Str.search_forward (Str.regexp_string "{{step") result 0 in true with Not_found -> false))

(* ═══ Chain_trace_types ═══ *)

let test_trace_to_entry () =
  let trace = { Chain_trace_types.timestamp = 1000.0; node_id = "n1";
                event = NodeStart { node_type = "model"; attempt = 1 } } in
  let entry = Chain_trace_types.trace_to_entry trace "test_node" in
  check string "node_id" "n1" entry.Chain_types.node_id;
  check string "node_type" "model" entry.node_type_name;
  check bool "success" true (entry.status = `Success)

let test_trace_complete () =
  let trace = { Chain_trace_types.timestamp = 1000.0; node_id = "n2";
                event = NodeComplete { duration_ms = 500; success = true; node_type = "tool"; attempt = 1 } } in
  let entry = Chain_trace_types.trace_to_entry trace "test" in
  check string "node_type" "tool" entry.Chain_types.node_type_name;
  check bool "success" true (entry.status = `Success)

let test_trace_error () =
  let trace = { Chain_trace_types.timestamp = 1000.0; node_id = "n3";
                event = NodeError { message = "boom"; error_class = Some "timeout"; node_type = "model"; attempt = 2 } } in
  let entry = Chain_trace_types.trace_to_entry trace "test" in
  check bool "failure" true (entry.Chain_types.status = `Failure);
  check (option string) "error msg" (Some "boom") entry.error

let test_trace_chain_start () =
  let trace = { Chain_trace_types.timestamp = 1000.0; node_id = "c1";
                event = ChainStart { chain_id = "chain-1"; mermaid_dsl = Some "graph LR" } } in
  let entry = Chain_trace_types.trace_to_entry trace "chain" in
  check string "node_id" "c1" entry.Chain_types.node_id;
  check bool "success" true (entry.status = `Success)

let test_trace_chain_complete () =
  let trace = { Chain_trace_types.timestamp = 1000.0; node_id = "c1";
                event = ChainComplete { chain_id = "chain-1"; success = true } } in
  let entry = Chain_trace_types.trace_to_entry trace "chain" in
  check bool "success" true (entry.Chain_types.status = `Success)

let test_traces_to_entries () =
  let traces = [
    { Chain_trace_types.timestamp = 1.0; node_id = "a"; event = NodeStart { node_type = "model"; attempt = 1 } };
    { timestamp = 2.0; node_id = "b"; event = NodeComplete { duration_ms = 100; success = true; node_type = "tool"; attempt = 1 } };
  ] in
  let entries = Chain_trace_types.traces_to_entries traces in
  check int "count" 2 (List.length entries)

(* ═══ Chain_conversation ═══ *)

let test_estimate_tokens () =
  check int "empty" 0 (Chain_conversation.estimate_tokens "");
  check int "4 chars" 1 (Chain_conversation.estimate_tokens "abcd");
  check int "8 chars" 2 (Chain_conversation.estimate_tokens "abcdefgh")

let test_make_conv () =
  let conv = Chain_conversation.make () in
  check int "empty history" 0 (List.length conv.history);
  check string "first model" "gemini" conv.current_model;
  check int "model_index" 0 conv.model_index

let test_make_conv_custom () =
  let conv = Chain_conversation.make ~models:["a";"b"] ~token_threshold:500 ~window_size:3 () in
  check int "models" 2 (List.length conv.models);
  check int "threshold" 500 conv.token_threshold;
  check int "window" 3 conv.window_size

let test_add_message () =
  let conv = Chain_conversation.make () in
  Chain_conversation.add_message conv ~role:"user" ~content:"hi" ~iteration:1 ~model:"gemini";
  check int "1 msg" 1 (List.length conv.history)

let test_rotate_model () =
  let conv = Chain_conversation.make ~models:["a";"b";"c"] () in
  check string "initial" "a" conv.current_model;
  Chain_conversation.rotate_model conv;
  check string "after rotate" "b" conv.current_model;
  Chain_conversation.rotate_model conv;
  check string "after 2nd" "c" conv.current_model;
  Chain_conversation.rotate_model conv;
  check string "wrap" "a" conv.current_model

let test_needs_summarization () =
  let conv = Chain_conversation.make ~token_threshold:10 () in
  check bool "empty no" false (Chain_conversation.needs_summarization conv);
  (* Add enough messages to exceed threshold *)
  for i = 1 to 20 do
    Chain_conversation.add_message conv ~role:"user" ~content:(String.make 100 'x') ~iteration:i ~model:"m"
  done;
  check bool "over threshold" true (Chain_conversation.needs_summarization conv)

let test_build_context_prompt () =
  let conv = Chain_conversation.make () in
  Chain_conversation.add_message conv ~role:"user" ~content:"hello" ~iteration:1 ~model:"m";
  Chain_conversation.add_message conv ~role:"assistant" ~content:"world" ~iteration:1 ~model:"m";
  let prompt = Chain_conversation.build_context_prompt conv in
  check bool "contains hello" true (try let _ = Str.search_forward (Str.regexp_string "hello") prompt 0 in true with Not_found -> false)

let test_estimate_conversation_tokens () =
  let conv = Chain_conversation.make () in
  let t0 = Chain_conversation.estimate_conversation_tokens conv in
  check int "empty" 0 t0;
  Chain_conversation.add_message conv ~role:"user" ~content:"abcd" ~iteration:1 ~model:"m";
  let t1 = Chain_conversation.estimate_conversation_tokens conv in
  check bool "positive" true (t1 > 0)

(* ═══ Safe_parse ═══ *)
module SP = Masc_mcp.Safe_parse
let test_sp_int_ok () =
  check int "parse" 42 (SP.int ~context:"test" ~default:0 "42")

let test_sp_int_fail () =
  check int "fallback" 99 (SP.int ~context:"test" ~default:99 "abc")

let test_sp_int_opt () =
  check (option int) "ok" (Some 5) (SP.int_opt "5");
  check (option int) "fail" None (SP.int_opt "xyz")

let test_sp_float_ok () =
  let v = SP.float ~context:"t" ~default:0.0 "3.14" in
  check bool "close" true (Float.abs (v -. 3.14) < 0.001)

let test_sp_float_fail () =
  let v = SP.float ~context:"t" ~default:1.5 "nope" in
  check bool "fallback" true (Float.abs (v -. 1.5) < 0.001)

let test_sp_float_opt () =
  check (option (Alcotest.testable (Fmt.float) (fun a b -> Float.abs (a -. b) < 0.001))) "ok" (Some 2.5) (SP.float_opt "2.5");
  check (option int) "fail" None (SP.int_opt "xyz")

let test_sp_bool () =
  check bool "true" true (SP.bool ~context:"t" ~default:false "true");
  check bool "1" true (SP.bool ~context:"t" ~default:false "1");
  check bool "yes" true (SP.bool ~context:"t" ~default:false "yes");
  check bool "false" false (SP.bool ~context:"t" ~default:true "false");
  check bool "0" false (SP.bool ~context:"t" ~default:true "0");
  check bool "no" false (SP.bool ~context:"t" ~default:true "no");
  check bool "fallback" true (SP.bool ~context:"t" ~default:true "maybe")

let test_sp_json_of_string () =
  check (option string) "ok" (Some "ok") (match SP.json_of_string_opt {|"ok"|} with Some (`String s) -> Some s | _ -> None);
  check bool "fail" true (SP.json_of_string_opt "{{bad" = None)

let test_sp_json_of_string_default () =
  let v = SP.json_of_string ~context:"t" ~default:`Null "{{bad" in
  check bool "null" true (v = `Null)

let test_sp_try_or () =
  let v = SP.try_or ~context:"t" ~fallback:(fun () -> 99) (fun () -> 42) in
  check int "ok" 42 v;
  let v2 = SP.try_or ~context:"t" ~fallback:(fun () -> 99) (fun () -> failwith "boom") in
  check int "fallback" 99 v2

let test_sp_try_opt () =
  check (option int) "ok" (Some 42) (SP.try_opt ~context:"t" (fun () -> 42));
  check (option int) "fail" None (SP.try_opt ~context:"t" (fun () -> failwith "boom"))

(* ═══ Registration ═══ *)

let () =
  run "Chain utils/iteration/trace/conversation coverage" [
    "utils:list", [
      test_case "nth_opt valid" `Quick test_list_nth_opt_valid;
      test_case "nth_opt oob" `Quick test_list_nth_opt_oob;
      test_case "hd_opt" `Quick test_list_hd_opt;
      test_case "tl_safe" `Quick test_list_tl_safe;
      test_case "uncons" `Quick test_list_uncons;
      test_case "last_opt" `Quick test_list_last_opt;
    ];
    "utils:string", [
      test_case "starts_with" `Quick test_starts_with;
      test_case "ends_with" `Quick test_ends_with;
      test_case "sub_opt" `Quick test_string_sub_opt;
      test_case "truncate" `Quick test_truncate;
      test_case "strip_prefix" `Quick test_strip_prefix;
      test_case "strip_suffix" `Quick test_strip_suffix;
      test_case "string_contains" `Quick test_string_contains;
    ];
    "utils:misc", [
      test_case "is_empty_response" `Quick test_is_empty_response;
      test_case "is_complex_prompt" `Quick test_is_complex_prompt;
      test_case "is_glm_model" `Quick test_is_glm_model;
    ];
    "iteration", [
      test_case "no ctx" `Quick test_substitute_none;
      test_case "basic" `Quick test_substitute_basic;
      test_case "strategy" `Quick test_substitute_strategy;
      test_case "linear" `Quick test_substitute_linear;
      test_case "step" `Quick test_substitute_step;
    ];
    "trace_types", [
      test_case "node_start" `Quick test_trace_to_entry;
      test_case "node_complete" `Quick test_trace_complete;
      test_case "node_error" `Quick test_trace_error;
      test_case "chain_start" `Quick test_trace_chain_start;
      test_case "chain_complete" `Quick test_trace_chain_complete;
      test_case "traces_to_entries" `Quick test_traces_to_entries;
    ];
    "conversation", [
      test_case "estimate_tokens" `Quick test_estimate_tokens;
      test_case "make default" `Quick test_make_conv;
      test_case "make custom" `Quick test_make_conv_custom;
      test_case "add_message" `Quick test_add_message;
      test_case "rotate_model" `Quick test_rotate_model;
      test_case "needs_summarization" `Quick test_needs_summarization;
      test_case "build_context_prompt" `Quick test_build_context_prompt;
      test_case "estimate_conv_tokens" `Quick test_estimate_conversation_tokens;
    ];
    "safe_parse:primitives", [
      test_case "int ok" `Quick test_sp_int_ok;
      test_case "int fail" `Quick test_sp_int_fail;
      test_case "int_opt" `Quick test_sp_int_opt;
      test_case "float ok" `Quick test_sp_float_ok;
      test_case "float fail" `Quick test_sp_float_fail;
      test_case "float_opt" `Quick test_sp_float_opt;
      test_case "bool" `Quick test_sp_bool;
    ];
    "safe_parse:json", [
      test_case "json_of_string" `Quick test_sp_json_of_string;
      test_case "json_of_string_default" `Quick test_sp_json_of_string_default;
    ];
    "safe_parse:try", [
      test_case "try_or" `Quick test_sp_try_or;
      test_case "try_opt" `Quick test_sp_try_opt;
    ];
  ]
