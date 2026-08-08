(** Async Agent example — run agents concurrently on Eio fibers.

    Demonstrates:
    - [Async_agent.spawn] / [await] for a background agent run
    - [Async_agent.race] to take the first successful result
    - [Async_agent.all] to collect results from several agents
    - Async agents using the same tool bundle as synchronous agents

    Tool descriptors carry [execution_mode] just like synchronous tool calls.
    The caller declares whether calls may overlap or must retain order; OAS
    does not infer this from effects.

    Prerequisites:
    - A running llama-server (or any OpenAI-compatible endpoint) on port 8085

    Usage:
      dune exec examples/async_agent_demo.exe *)

open Agent_sdk
open Types

let read_only_tool =
  let descriptor = Tool.ordinary_descriptor Concurrent in
  Tool.create
    ~descriptor
    ~name:"lookup"
    ~description:"Lookup a value"
    ~parameters:
      [ { name = "key"
        ; description = "Key to look up"
        ; param_type = String
        ; required = true
        }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       match args |> member "key" |> to_string_option with
       | Some key ->
         Ok { Types.content = Printf.sprintf "value for %s" key; _meta = None }
       | None ->
         Error
           { Types.message = "missing 'key' parameter"
           ; recoverable = true
           ; error_class = None
           })
;;

(** This simulated client declares serial execution. OAS does not recognize the
    URL or tool name to choose that mode. *)
let external_fetch_tool =
  let descriptor = Tool.ordinary_descriptor Serial in
  Tool.create
    ~descriptor
    ~name:"fetch_url"
    ~description:"Fetch a URL (simulated)"
    ~parameters:
      [ { name = "url"
        ; description = "URL to fetch"
        ; param_type = String
        ; required = true
        }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       match args |> member "url" |> to_string_option with
       | Some url -> Ok { Types.content = Printf.sprintf "Fetched: %s" url; _meta = None }
       | None ->
         Error
           { Types.message = "missing 'url' parameter"
           ; recoverable = true
           ; error_class = None
           })
;;

let make_agent ~net name =
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"qwen3.5"
      ~base_url:"http://127.0.0.1:8085"
      ()
  in
  let config =
    { (default_config ~model:provider_config.model_id) with
      name
    ; system_prompt = Some "You have a lookup tool. Use it when helpful. Be concise."
    }
  in
  let options = { Agent.default_options with provider_config = Some provider_config } in
  Agent.create ~net ~config ~options ~tools:[ read_only_tool; external_fetch_tool ] ()
;;

let extract_text (resp : Types.api_response) =
  List.filter_map
    (function
      | Types.Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat " "
;;

let () =
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  (* 1. Spawn a single background agent and await its result. *)
  let agent_a = make_agent ~net "async-a" in
  let future_a = Async_agent.spawn ~sw ~clock agent_a "Look up 'fibonacci'." in
  (match Async_agent.await future_a with
   | Ok resp -> Printf.printf "[spawn] %s\n" (extract_text resp)
   | Error e -> Printf.eprintf "[spawn] error: %s\n" (Error.to_string e));
  (* 2. Race two agents; the first to finish wins, the other is cancelled. *)
  let agent_b = make_agent ~net "racer-b" in
  let agent_c = make_agent ~net "racer-c" in
  (match
     Async_agent.race
       ~sw
       ~clock
       [ agent_b, "Look up 'ocaml'."; agent_c, "Look up 'eio'." ]
   with
   | Ok (name, resp) ->
     Printf.printf "[race] winner=%s result=%s\n" name (extract_text resp)
   | Error e -> Printf.eprintf "[race] error: %s\n" (Error.to_string e));
  (* 3. Run several agents in parallel and collect all results. *)
  let agents =
    [ make_agent ~net "fan-1", "Look up 'agent'."
    ; make_agent ~net "fan-2", "Look up 'sdk'."
    ; make_agent ~net "fan-3", "Look up 'fiber'."
    ]
  in
  match Async_agent.all ~sw ~clock ~max_fibers:3 agents with
  | [] -> Printf.eprintf "[all] no results\n"
  | results ->
    List.iter
      (fun (name, result) ->
         match result with
         | Ok resp -> Printf.printf "[all] %s -> %s\n" name (extract_text resp)
         | Error e -> Printf.eprintf "[all] %s error: %s\n" name (Error.to_string e))
      results
;;
