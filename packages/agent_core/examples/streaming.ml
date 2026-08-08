(** SSE streaming example.

    Demonstrates:
    - Setting up a streaming API call via {!Llm_provider.Complete.complete_stream}
    - Processing events in real-time via on_event callback
    - Tracking usage statistics

    Prerequisites:
    - A running llama-server on port 8085 (or set provider accordingly)

    Usage:
      dune exec examples/streaming.exe *)

open Agent_sdk
open Types

let on_event = function
  | ContentBlockDelta { delta = TextDelta s; _ } ->
    print_string s;
    flush stdout
  | ContentBlockDelta { delta = ThinkingDelta _; _ } ->
    print_string ".";
    flush stdout
  | MessageStart { model; _ } -> Printf.printf "[model: %s]\n" model
  | MessageStop -> print_newline ()
  | _ -> ()
;;

let () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run
  @@ fun sw ->
  let api_key =
    Option.value ~default:"" (Sys.getenv_opt "OAS_STREAMING_EXAMPLE_API_KEY")
  in
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"qwen3.5-35b"
      ~base_url:"http://127.0.0.1:8085"
      ~api_key
      ~request_path:"/v1/chat/completions"
      ~system_prompt:"You are a helpful assistant."
      ~max_tokens:1024
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "Explain monads in one paragraph." ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  match Llm_provider.Complete.complete_stream ~sw ~net ~config ~messages ~on_event () with
  | Ok response ->
    Printf.printf "\nResponse ID: %s\n" response.id;
    (match response.usage with
     | Some u -> Printf.printf "Tokens: %d in / %d out\n" u.input_tokens u.output_tokens
     | None -> ())
  | Error e ->
    Printf.eprintf "Error: %s\n" Llm_provider.Error.(to_string (of_http_error e))
;;
