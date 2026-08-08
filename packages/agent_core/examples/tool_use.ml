(** Tool definition and execution example.

    Demonstrates:
    - Defining a tool with parameters and JSON schema
    - Simple handler (pure function)
    - Context-aware handler (stateful via Context.t)
    - Caller-declared execution mode via [Tool.descriptor]

    [Tool.descriptor_execution_mode] tells the OAS runtime whether calls may be
    batched concurrently or must execute serially.

    OAS never derives this structural choice from a tool name or effect.

    Prerequisites:
    - A running llama-server on port 8085

    Usage:
      dune exec examples/tool_use.exe *)

open Agent_sdk
open Types

(** A pure tool whose implementation explicitly permits overlapping calls. *)
let calculator_tool =
  let descriptor = Tool.ordinary_descriptor Concurrent in
  Tool.create
    ~descriptor
    ~name:"calculator"
    ~description:"Evaluate a math expression"
    ~parameters:
      [ { name = "expression"
        ; description = "The math expression to evaluate"
        ; param_type = String
        ; required = true
        }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       match args |> member "expression" |> to_string_option with
       | Some expr ->
         Ok { Types.content = Printf.sprintf "Result of '%s': 42" expr; _meta = None }
       | None ->
         Error
           { Types.message = "missing 'expression' parameter"
           ; recoverable = true
           ; error_class = None
           })
;;

(** An HTTP-like tool whose simulated client must execute serially. *)
let weather_api_tool =
  let descriptor = Tool.ordinary_descriptor Serial in
  Tool.create
    ~descriptor
    ~name:"weather"
    ~description:"Fetch current weather for a city"
    ~parameters:
      [ { name = "city"; description = "City name"; param_type = String; required = true }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       match args |> member "city" |> to_string_option with
       | Some city ->
         Ok { Types.content = Printf.sprintf "Weather in %s: sunny" city; _meta = None }
       | None ->
         Error
           { Types.message = "missing 'city' parameter"
           ; recoverable = true
           ; error_class = None
           })
;;

(** A stateful tool whose context updates must retain call order. *)
let counter_tool =
  let descriptor = Tool.ordinary_descriptor Serial in
  Tool.of_schema
    ~descriptor
    (Types.tool_schema_of_params
       ~name:"counter"
       ~description:"Increment and return a counter"
       ~parameters:[]
       ())
    (Tool.requiring_context (fun ctx _input ->
       let n =
         match Context.get ctx "count" with
         | Some (`Int n) -> n + 1
         | _ -> 1
       in
       Context.set ctx "count" (`Int n);
       Ok { Types.content = string_of_int n; _meta = None }))
;;

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
      name = "tool-demo"
    ; system_prompt =
        Some "You have access to a calculator, a weather API, and a counter. Use them."
    }
  in
  let agent =
    Agent.create
      ~net
      ~config
      ~options:{ Agent.default_options with provider_config = Some provider_config }
      ~tools:[ calculator_tool; weather_api_tool; counter_tool ]
      ()
  in
  match Agent.run ~sw agent "Calculate 6 * 7, then increment the counter twice." with
  | Ok response ->
    List.iter
      (function
        | Text t -> Printf.printf "%s\n" t
        | ToolUse { id; name; _ } -> Printf.printf "[tool_use] %s (id=%s)\n" name id
        | ToolResult { content; outcome; _ } ->
          Printf.printf
            "[tool_result] %s (error=%b)\n"
            content
            (tool_result_outcome_is_error outcome)
        | _ -> ())
      response.content
  | Error e -> Printf.eprintf "Error: %s\n" (Error.to_string e)
;;
