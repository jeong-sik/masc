(** Builder patterns example: all Builder API methods and validation.

    Demonstrates:
    - Builder.create -> chain -> build_safe
    - Minimal vs full configuration
    - Validation errors from build_safe
    - with_hooks, with_provider_config
    - with_context, with_initial_messages

    Prerequisites:
    - A running llama-server on port 8085

    Usage:
      dune exec examples/builder_patterns.exe *)

open Agent_sdk
open Types

let local_provider_config ~model_id =
  Llm_provider.Provider_config.make
    ~kind:OpenAI_compat
    ~model_id
    ~base_url:"http://127.0.0.1:8085"
    ()
;;

(* ── 1. Minimal builder ──────────────────────────────── *)

let demo_minimal () =
  Printf.printf "--- 1. Minimal Builder ---\n";
  Eio_main.run
  @@ fun env ->
  let provider_config = local_provider_config ~model_id:"test-model" in
  let agent =
    Builder.create ~net:env#net ~model:provider_config.model_id
    |> Builder.with_name "minimal"
    |> Builder.with_provider_config provider_config
    |> Builder.build_safe
    |> Result.get_ok
  in
  Printf.printf
    "  Created agent: %s (model=%s)\n"
    (Agent.state agent).config.name
    (Agent.state agent).config.model
;;

(* ── 2. Full-featured builder ────────────────────────── *)

let demo_full () =
  Printf.printf "\n--- 2. Full-featured Builder ---\n";
  Eio_main.run
  @@ fun env ->
  let echo_tool =
    Tool.create ~name:"echo" ~description:"Echo input" ~parameters:[] (fun _input ->
      Ok { content = "echoed"; _meta = None })
  in
  let hooks =
    { Hooks.empty with
      before_turn =
        Some
          (fun _ ->
            Printf.eprintf "  [hook] turn\n%!";
            Continue)
    ; on_stop =
        Some
          (fun _ ->
            Printf.eprintf "  [hook] stop\n%!";
            Continue)
    }
  in
  let result =
    let provider_config = local_provider_config ~model_id:"test-model" in
    Builder.create ~net:env#net ~model:provider_config.model_id
    |> Builder.with_name "full-demo"
    |> Builder.with_provider_config provider_config
    |> Builder.with_system_prompt "You are a helpful assistant."
    |> Builder.with_max_tokens 1024
    |> Builder.with_temperature 0.7
    |> Builder.with_tools [ echo_tool ]
    |> Builder.with_hooks hooks
    |> Builder.with_initial_messages
         [ { role = User
           ; content = [ Text "context: this is a demo" ]
           ; name = None
           ; tool_call_id = None
           ; metadata = []
           }
         ]
    |> Builder.build_safe
  in
  match result with
  | Ok agent ->
    let st = Agent.state agent in
    Printf.printf "  Agent: %s\n" st.config.name;
    Printf.printf "  Tools: %d\n" (Tool_set.size (Agent.tools agent));
    Printf.printf "  Initial messages: %d\n" (List.length st.config.initial_messages)
  | Error e -> Printf.printf "  Build failed: %s\n" (Error.to_string e)
;;

(* ── 3. Validation error ─────────────────────────────── *)

let demo_validation_error () =
  Printf.printf "\n--- 3. Validation Error ---\n";
  Eio_main.run
  @@ fun env ->
  let provider_config = local_provider_config ~model_id:"test-model" in
  let result =
    Builder.create ~net:env#net ~model:provider_config.model_id
    |> Builder.with_provider_config provider_config
    |> Builder.with_max_tokens (-1) (* invalid provider request bound *)
    |> Builder.build_safe
  in
  match result with
  | Ok _ -> Printf.printf "  (no validation error for negative max_tokens)\n"
  | Error e -> Printf.printf "  Expected error: %s\n" (Error.to_string e)
;;

(* ── 4. Context sharing ──────────────────────────────── *)

let demo_context () =
  Printf.printf "\n--- 4. Context Sharing ---\n";
  Eio_main.run
  @@ fun env ->
  let ctx = Context.create () in
  Context.set ctx "shared_key" (`String "shared_value");
  let provider_config = local_provider_config ~model_id:"test-model" in
  let agent =
    Builder.create ~net:env#net ~model:provider_config.model_id
    |> Builder.with_name "ctx-demo"
    |> Builder.with_provider_config provider_config
    |> Builder.with_context ctx
    |> Builder.build_safe
    |> Result.get_ok
  in
  let agent_ctx = Agent.context agent in
  let value = Context.get agent_ctx "shared_key" in
  Printf.printf
    "  Context value: %s\n"
    (match value with
     | Some (`String s) -> s
     | _ -> "not found")
;;

(* ── Main ────────────────────────────────────────────── *)

let () =
  Printf.printf "=== Builder Patterns Demo ===\n\n";
  demo_minimal ();
  demo_full ();
  demo_validation_error ();
  demo_context ();
  Printf.printf "\nDone.\n"
;;
