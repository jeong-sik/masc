(** Error handling example: graceful recovery from tool failures.

    Demonstrates:
    - Tool handler returning Error with recoverable flag
    - Error.sdk_error variant matching
    - on_error hook for error logging
    - Agent behavior on tool errors (error becomes tool_result)

    Prerequisites:
    - A running llama-server on port 8085

    Usage:
      dune exec examples/error_handling.exe *)

open Agent_sdk
open Types

(* ── A tool that fails on certain inputs ─────────────── *)

let fragile_tool =
  Tool.create
    ~name:"read_file"
    ~description:"Read a file. Fails if file does not exist."
    ~parameters:
      [ { name = "path"; description = "File path"; param_type = String; required = true }
      ]
    (fun args ->
       let path = Yojson.Safe.Util.(args |> member "path" |> to_string) in
       if Sys.file_exists path
       then Ok { content = Printf.sprintf "Contents of %s: [data]" path; _meta = None }
       else
         Error
           { message = Printf.sprintf "File not found: %s" path
           ; recoverable = true
           ; error_class = None
           })
;;

(* ── Error logging hook ──────────────────────────────── *)

let error_hooks : Hooks.hooks =
  { Hooks.empty with
    on_tool_error =
      Some
        (function
          | OnToolError { tool_name; error; invocation = _ } ->
            Printf.eprintf "[error-hook] Tool %s failed: %s\n%!" tool_name error;
            Continue
          | _ -> Continue)
  }
;;

(* ── Main ────────────────────────────────────────────── *)

let () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"qwen3.5"
      ~base_url:"http://127.0.0.1:8085"
      ()
  in
  let options =
    { Agent.default_options with
      hooks = error_hooks
    ; provider_config = Some provider_config
    }
  in
  let config =
    { (default_config ~model:provider_config.model_id) with
      name = "error-demo"
    ; system_prompt = Some "Try to read /tmp/nonexistent.txt."
    }
  in
  let agent = Agent.create ~net:env#net ~config ~options ~tools:[ fragile_tool ] () in
  match Agent.run ~sw agent "Read /tmp/nonexistent.txt" with
  | Ok resp ->
    Printf.printf "Agent completed.\n";
    List.iter
      (function
        | Text t -> Printf.printf "  %s\n" t
        | ToolResult { content; outcome; _ } ->
          Printf.printf
            "  [tool_result error=%b] %s\n"
            (tool_result_outcome_is_error outcome)
            content
        | _ -> ())
      resp.content
  | Error e ->
    (* Match specific error variants *)
    (match e with
     | Error.Agent _ -> Printf.eprintf "Agent error: %s\n" (Error.to_string e)
     | Error.Config _ -> Printf.eprintf "Config error: %s\n" (Error.to_string e)
     | Error.Internal msg -> Printf.eprintf "Internal error: %s\n" msg
     | _ -> Printf.eprintf "Other error: %s\n" (Error.to_string e))
;;
