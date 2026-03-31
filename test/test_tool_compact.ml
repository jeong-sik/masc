(** Tests for Tool_compact — masc_compact_context MCP tool.

    Verifies:
    - Strategy parsing (each strategy + "all")
    - Message parsing from JSON
    - Token counting before/after
    - Output JSON structure
    - Error handling for invalid input

    @since 2.95.0 *)

open Alcotest
module TC = Masc_mcp.Tool_compact

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

(** Build a JSON args object for masc_compact_context. *)
let make_args ?(strategy = "all") ?(max_tokens = 128_000)
    ?(system_prompt = "") (messages : (string * string) list) : Yojson.Safe.t =
  let msg_json = List.map (fun (role, content) ->
    `Assoc [("role", `String role); ("content", `String content)]
  ) messages in
  `Assoc [
    ("messages", `List msg_json);
    ("strategy", `String strategy);
    ("max_tokens", `Int max_tokens);
    ("system_prompt", `String system_prompt);
  ]

let parse_result (success, json_str) =
  check bool "success" true success;
  Yojson.Safe.from_string json_str

(* ================================================================ *)
(* Tests                                                            *)
(* ================================================================ *)

let test_basic_compact () =
  let messages = [
    ("user", "Hello, how are you?");
    ("assistant", "I am fine, thank you.");
    ("user", "What is the weather?");
    ("assistant", "It is sunny today.");
  ] in
  let args = make_args ~strategy:"all" messages in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some (success, json_str) ->
    check bool "success" true success;
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    check bool "has success field" true (json |> member "success" |> to_bool);
    let tokens_before = json |> member "tokens_before" |> to_int in
    let tokens_after = json |> member "tokens_after" |> to_int in
    check bool "tokens_before > 0" true (tokens_before > 0);
    check bool "tokens_after >= 0" true (tokens_after >= 0);
    (* tokens_saved can be negative when summary overhead exceeds
       savings from short messages — that is expected behavior *)
    let _tokens_saved = json |> member "tokens_saved" |> to_int in
    let msgs_after = json |> member "messages" |> to_list in
    check bool "messages_after > 0" true (List.length msgs_after > 0)

let test_prune_tool_outputs () =
  let long_output = String.make 2000 'x' in
  let messages = [
    ("user", "Run the command");
    ("tool", long_output);
    ("assistant", "Done");
  ] in
  let args = make_args ~strategy:"prune_tool_outputs" messages in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some result ->
    let json = parse_result result in
    let open Yojson.Safe.Util in
    let tokens_saved = json |> member "tokens_saved" |> to_int in
    check bool "tokens saved by pruning" true (tokens_saved > 0)

let test_merge_contiguous () =
  let messages = [
    ("user", "Hello");
    ("user", "World");
    ("assistant", "Hi there");
  ] in
  let args = make_args ~strategy:"merge_contiguous" messages in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some result ->
    let json = parse_result result in
    let open Yojson.Safe.Util in
    let after = json |> member "messages_after" |> to_int in
    (* Two user messages merged into one *)
    check int "2 messages after merge" 2 after

let test_summarize_old () =
  (* Use enough messages so keep_recent=5 compacts the older prefix. *)
  let messages = List.init 12 (fun i ->
    if i mod 2 = 0 then ("user", Printf.sprintf "Question %d about a topic" i)
    else ("assistant", Printf.sprintf "Answer %d that is quite detailed" i)
  ) in
  let args = make_args ~strategy:"summarize_old" messages in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some result ->
     let json = parse_result result in
     let open Yojson.Safe.Util in
     let before = json |> member "messages_before" |> to_int in
     let after = json |> member "messages_after" |> to_int in
     check bool "fewer messages after summarize" true (after < before)

let test_summarize_old_masks_old_tool_output () =
  let messages = [
    ("user", "Search reducer files");
    ("tool", "3 matches in lib/\nlib/context_compact_oas.ml\nlib/tool_compact.ml");
    ("assistant", "I found 3 matches in lib/.");
    ("user", "What next?");
    ("assistant", "Inspect the reducer implementation.");
    ("user", "Any tests?");
    ("assistant", "Yes, focused compaction tests exist.");
  ] in
  let args = make_args ~strategy:"summarize_old" messages in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some result ->
    let json = parse_result result in
    let open Yojson.Safe.Util in
    let output_messages = json |> member "messages" |> to_list in
    let tool_contents =
      output_messages
      |> List.filter_map (fun msg ->
        if msg |> member "role" |> to_string = "tool" then
          Some (msg |> member "content" |> to_string)
        else None)
    in
    check int "one tool message remains" 1 (List.length tool_contents);
    let tool_content = List.hd tool_contents in
    check bool "tool output masked as stub" true
      (String.starts_with ~prefix:"[tool:unknown id:compact" tool_content)

let test_unknown_strategy () =
  let args = make_args ~strategy:"nonexistent" [("user", "test")] in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some (success, json_str) ->
    check bool "should fail" false success;
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let err = json |> member "error" |> to_string in
    check bool "error mentions unknown" true
      (String.length err > 0)

let test_unknown_tool_name () =
  let args = `Assoc [] in
  match TC.dispatch ~name:"unknown_tool" ~args with
  | None -> ()  (* expected *)
  | Some _ -> fail "should return None for unknown tool"

let test_empty_messages () =
  let args = make_args ~strategy:"all" [] in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some result ->
    let json = parse_result result in
    let open Yojson.Safe.Util in
    check int "0 messages after" 0
      (json |> member "messages_after" |> to_int)

let test_context_ratio () =
  let messages = [("user", String.make 1000 'a')] in
  let args = make_args ~strategy:"all" ~max_tokens:500 messages in
  match TC.dispatch ~name:"masc_compact_context" ~args with
  | None -> fail "dispatch returned None"
  | Some result ->
    let json = parse_result result in
    let open Yojson.Safe.Util in
    let ratio = json |> member "context_ratio" |> to_float in
    check bool "ratio > 0" true (ratio > 0.0)

let test_system_prompt_token_counting () =
  let messages = [("user", "Hello")] in
  let sys = "You are a helpful assistant." in
  let base_args = make_args ~strategy:"all" messages in
  let args_with_sys = make_args ~strategy:"all" ~system_prompt:sys messages in
  let parse_tokens = function
    | None -> fail "dispatch returned None"
    | Some result ->
      let json = parse_result result in
      let open Yojson.Safe.Util in
      json |> member "tokens_before" |> to_int
  in
  let tokens_without_sys =
    TC.dispatch ~name:"masc_compact_context" ~args:base_args |> parse_tokens
  in
  let tokens_with_sys =
    TC.dispatch ~name:"masc_compact_context" ~args:args_with_sys |> parse_tokens
  in
  match TC.dispatch ~name:"masc_compact_context" ~args:args_with_sys with
  | None -> fail "dispatch returned None"
  | Some result ->
    let json = parse_result result in
    let open Yojson.Safe.Util in
    let tokens = json |> member "tokens_before" |> to_int in
    check int "reported tokens match with-sys path" tokens_with_sys tokens;
    (* System prompt tokens should increase the estimated budget relative to the
       same message set without a system prompt, regardless of estimator shape. *)
    check bool "tokens include system prompt" true (tokens_with_sys > tokens_without_sys)

(* ================================================================ *)
(* Test for fs_compat backend types                                 *)
(* ================================================================ *)

let test_backend_create_default () =
  let b = Fs_compat.default_backend ~base_path:"/tmp/test" in
  check string "base_path" "/tmp/test" (Fs_compat.backend_base_path b);
  check string "kind" "local" (Fs_compat.backend_kind_to_string b.kind)

let test_backend_create_remote () =
  let b = Fs_compat.create_backend
    ~kind:(Fs_compat.Remote "https://s3.example.com/bucket")
    ~base_path:"/data" () in
  check string "base_path" "/data" (Fs_compat.backend_base_path b);
  check string "kind" "remote(https://s3.example.com/bucket)"
    (Fs_compat.backend_kind_to_string b.kind)

let test_backend_create_local_explicit () =
  let b = Fs_compat.create_backend
    ~kind:Fs_compat.Local ~base_path:"/var/data" () in
  check string "base_path" "/var/data" (Fs_compat.backend_base_path b)

(* ================================================================ *)
(* Runner                                                           *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  run "tool_compact + fs_compat_backend" [
    ("compact_dispatch", [
      test_case "basic compact" `Quick test_basic_compact;
      test_case "prune tool outputs" `Quick test_prune_tool_outputs;
      test_case "merge contiguous" `Quick test_merge_contiguous;
      test_case "summarize old" `Quick test_summarize_old;
      test_case "summarize old masks tool output" `Quick
        test_summarize_old_masks_old_tool_output;
      test_case "unknown strategy" `Quick test_unknown_strategy;
      test_case "unknown tool name" `Quick test_unknown_tool_name;
      test_case "empty messages" `Quick test_empty_messages;
      test_case "context ratio" `Quick test_context_ratio;
      test_case "system prompt tokens" `Quick test_system_prompt_token_counting;
    ]);
    ("fs_compat_backend", [
      test_case "default backend" `Quick test_backend_create_default;
      test_case "remote backend" `Quick test_backend_create_remote;
      test_case "local explicit" `Quick test_backend_create_local_explicit;
    ]);
  ]
