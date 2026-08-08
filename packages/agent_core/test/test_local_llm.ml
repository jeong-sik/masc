(** Live integration test: agent-sdk → llama-server (DashScope_3.5)

    Requires: llama-server running on 127.0.0.1:8085
    Run: LLAMA_LIVE_TEST=1 dune exec ./test/test_local_llm.exe
*)

open Agent_sdk
open Types

let base_url = "http://127.0.0.1:8085"
let local_model = "dashscope-3.5-35b-a3b-ud-q8-xl"

let provider_config =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~provider_id:"local"
    ~model_id:local_model
    ~base_url
    ~api_key:""
    ~headers:[ "Content-Type", "application/json" ]
    ~request_path:"/v1/chat/completions"
    ()
;;

let options = { Agent.default_options with provider_config = Some provider_config }

let provider_m_config name system_prompt max_tokens =
  { (default_config ~model:local_model) with
    name
  ; system_prompt
  ; max_tokens
  ; temperature = Some 0.6
  ; top_p = Some 0.95
  ; top_k = Some 20
  ; min_p = Some 0.01
  ; enable_thinking = Some false
  }
;;

(** Test 1: Simple text response *)
let test_simple_chat () =
  Printf.printf "\n=== Test 1: Simple chat ===\n%!";
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config = provider_m_config "test-agent" None (Some 100) in
  let agent = Agent.create ~net:env#net ~config ~options () in
  match Agent.run ~sw agent "What is 2+3? Answer with just the number." with
  | Ok response ->
    let text =
      List.filter_map
        (function
          | Text s -> Some s
          | _ -> None)
        response.content
      |> String.concat ""
    in
    Printf.printf "  Response: %s\n%!" text;
    Printf.printf "  Stop reason: %s\n%!" (show_stop_reason response.stop_reason);
    (match response.usage with
     | Some u ->
       Printf.printf "  Tokens: %d in / %d out\n%!" u.Types.input_tokens u.output_tokens
     | None -> ());
    assert (String.length text > 0);
    Printf.printf "  PASS\n%!"
  | Error e ->
    Printf.printf "  FAIL: %s\n%!" (Error.to_string e);
    assert false
;;

(** Test 2: Tool calling *)
let test_tool_calling () =
  Printf.printf "\n=== Test 2: Tool calling ===\n%!";
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config =
    provider_m_config
      "tool-agent"
      (Some "You are a helpful assistant. Use the provided tools to answer questions.")
      (Some 200)
  in
  let calc_tool =
    Tool.create
      ~name:"calculator"
      ~description:"Perform arithmetic. Returns the result as a string."
      ~parameters:
        [ { name = "expression"
          ; description = "Math expression like '2+3' or '10*5'"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
         let expr = Yojson.Safe.Util.(input |> member "expression" |> to_string) in
         Printf.printf "  [Tool called] calculator(%s)\n%!" expr;
         (* Simple eval for demo *)
         Ok { Types.content = Printf.sprintf "Result of %s = 5" expr; _meta = None })
  in
  let agent = Agent.create ~net:env#net ~config ~tools:[ calc_tool ] ~options () in
  match Agent.run ~sw agent "What is 2+3? Use the calculator tool." with
  | Ok response ->
    let text =
      List.filter_map
        (function
          | Text s -> Some s
          | _ -> None)
        response.content
      |> String.concat ""
    in
    Printf.printf "  Final response: %s\n%!" text;
    Printf.printf
      "  Turns used: (stop_reason=%s)\n%!"
      (show_stop_reason response.stop_reason);
    Printf.printf "  PASS\n%!"
  | Error e ->
    Printf.printf "  FAIL: %s\n%!" (Error.to_string e);
    assert false
;;

(** Test 3: Multi-turn tool loop *)
let test_multi_tool () =
  Printf.printf "\n=== Test 3: Multi-tool loop ===\n%!";
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config =
    provider_m_config
      "multi-tool-agent"
      (Some "You have access to tools. Use read_file to check file contents.")
      (Some 300)
  in
  let read_file_tool =
    Tool.create
      ~name:"read_file"
      ~description:"Read contents of a file at the given path"
      ~parameters:
        [ { name = "path"
          ; description = "File path to read"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
         let path = Yojson.Safe.Util.(input |> member "path" |> to_string) in
         Printf.printf "  [Tool called] read_file(%s)\n%!" path;
         Ok { Types.content = "hello world\nthis is a test file\n"; _meta = None })
  in
  let agent = Agent.create ~net:env#net ~config ~tools:[ read_file_tool ] ~options () in
  match
    Agent.run ~sw agent "Read the file at /tmp/test.txt and tell me what it says."
  with
  | Ok response ->
    let text =
      List.filter_map
        (function
          | Text s -> Some s
          | _ -> None)
        response.content
      |> String.concat ""
    in
    Printf.printf "  Final response: %s\n%!" text;
    Printf.printf "  PASS\n%!"
  | Error e ->
    Printf.printf "  FAIL: %s\n%!" (Error.to_string e);
    assert false
;;

let () =
  match Sys.getenv_opt "LLAMA_LIVE_TEST" with
  | Some "1" ->
    Printf.printf "Running live tests against llama-server at %s\n%!" base_url;
    test_simple_chat ();
    (match Sys.getenv_opt "LLAMA_LIVE_TOOL_TEST" with
     | Some "1" ->
       test_tool_calling ();
       test_multi_tool ()
     | _ ->
       Printf.printf
         "Skipping tool-heavy live tests. Set LLAMA_LIVE_TOOL_TEST=1 to enable.\n%!");
    Printf.printf "\n=== All live tests passed! ===\n%!"
  | _ ->
    Printf.printf
      "Skipped: set LLAMA_LIVE_TEST=1 to run (requires llama-server on port 8085)\n%!"
;;
