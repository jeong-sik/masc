(** Minimal agent example: create an agent and run a single turn.

    Prerequisites:
    - A running llama-server (or any OpenAI-compatible endpoint) on port 8085

    Usage:
      dune exec examples/basic_agent.exe *)

open Agent_sdk
open Types

let () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run
  @@ fun sw ->
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"qwen3.5"
      ~base_url:"http://127.0.0.1:8085"
      ()
  in
  let config =
    { (default_config ~model:provider_config.model_id) with
      name = "hello-agent"
    ; system_prompt = Some "You are a helpful assistant. Be concise."
    }
  in
  let options = { Agent.default_options with provider_config = Some provider_config } in
  let agent = Agent.create ~net ~config ~options ~tools:[] () in
  match Agent.run ~sw agent "What is 2 + 2? Answer in one word." with
  | Ok response ->
    List.iter
      (function
        | Text t -> Printf.printf "%s\n" t
        | _ -> ())
      response.content
  | Error e -> Printf.eprintf "Error: %s\n" (Error.to_string e)
;;
