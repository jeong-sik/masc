(** Code generation agent — natural language to OCaml code.

    Demonstrates:
    - Structured output extraction via tool_use
    - Multi-turn refinement (generate -> verify -> output)
    - Context-aware tools (file writing with verification)

    Prerequisites:
    - A running LLM (llama-server :8085 or set LLM_BASE_URL)
    - ocamlformat installed (for formatting)

    Usage:
      dune exec examples/codegen_agent.exe -- "Write a function that checks if a list is a palindrome"
      dune exec examples/codegen_agent.exe -- --file output.ml "Generate a binary search tree module" *)

open Agent_sdk
open Types

(* ── Tools ─────────────────────────────────────────────────── *)

let typecheck_tool =
  Tool.create
    ~name:"typecheck"
    ~description:"Typecheck OCaml code. Returns compiler output (errors or success)."
    ~parameters:
      [ { name = "code"
        ; description = "OCaml source code to typecheck"
        ; param_type = String
        ; required = true
        }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       match args |> member "code" |> to_string_option with
       | None ->
         Error
           { message = "missing code parameter"; recoverable = false; error_class = None }
       | Some code ->
         let tmp = Filename.temp_file "codegen" ".ml" in
         let oc = open_out tmp in
         output_string oc code;
         close_out oc;
         let cmd =
           Printf.sprintf
             "ocamlfind ocamlopt -package eio,eio_main -syntax camlp4o -typeonly %s \
              2>&1; echo \"EXIT:$?\""
             (Filename.quote tmp)
         in
         let ic = Unix.open_process_in cmd in
         let buf = Buffer.create 1024 in
         (try
            while true do
              Buffer.add_string buf (input_line ic);
              Buffer.add_char buf '\n'
            done
          with
          | End_of_file -> ());
         ignore (Unix.close_process_in ic);
         Sys.remove tmp;
         let output = Buffer.contents buf in
         if String.length output < 20
         then Ok { content = "Typecheck passed (no errors)."; _meta = None }
         else Ok { content = Printf.sprintf "Compiler output:\n%s" output; _meta = None })
;;

let format_tool =
  Tool.create
    ~name:"format"
    ~description:"Format OCaml code using ocamlformat. Returns formatted code."
    ~parameters:
      [ { name = "code"
        ; description = "OCaml source code to format"
        ; param_type = String
        ; required = true
        }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       match args |> member "code" |> to_string_option with
       | None ->
         Error
           { message = "missing code parameter"; recoverable = false; error_class = None }
       | Some code ->
         let tmp = Filename.temp_file "codegen" ".ml" in
         let oc = open_out tmp in
         output_string oc code;
         close_out oc;
         let cmd =
           Printf.sprintf
             "ocamlformat --enable-outside-detected-project %s 2>/dev/null || cat %s"
             (Filename.quote tmp)
             (Filename.quote tmp)
         in
         let ic = Unix.open_process_in cmd in
         let buf = Buffer.create 2048 in
         (try
            while true do
              Buffer.add_string buf (input_line ic);
              Buffer.add_char buf '\n'
            done
          with
          | End_of_file -> ());
         ignore (Unix.close_process_in ic);
         Sys.remove tmp;
         Ok { content = Buffer.contents buf; _meta = None })
;;

let write_file_tool =
  Tool.create
    ~name:"write_file"
    ~description:"Write OCaml code to a file"
    ~parameters:
      [ { name = "path"
        ; description = "File path to write to"
        ; param_type = String
        ; required = true
        }
      ; { name = "code"
        ; description = "OCaml source code"
        ; param_type = String
        ; required = true
        }
      ]
    (fun args ->
       let open Yojson.Safe.Util in
       let path = args |> member "path" |> to_string in
       let code = args |> member "code" |> to_string in
       (* Reject path traversal attempts *)
       if
         String.contains path '\000'
         || (String.length path > 2 && String.sub path 0 2 = "..")
         ||
         try
           ignore (Str.search_forward (Str.regexp_string "/../") path 0);
           true
         with
         | Not_found -> false
       then
         Error
           { message = Printf.sprintf "Rejected path: %s (path traversal)" path
           ; recoverable = false
           ; error_class = None
           }
       else (
         try
           let oc = open_out path in
           output_string oc code;
           close_out oc;
           Ok
             { content = Printf.sprintf "Written %d bytes to %s" (String.length code) path
             ; _meta = None
             }
         with
         | exn ->
           Error
             { message =
                 Printf.sprintf "Failed to write %s: %s" path (Printexc.to_string exn)
             ; recoverable = true
             ; error_class = None
             }))
;;

(* ── System prompt ─────────────────────────────────────────── *)

let system_prompt =
  {|You are an OCaml code generation agent. Your workflow:

1. Understand the user's request
2. Generate clean, idiomatic OCaml 5.x code
3. Use the typecheck tool to verify your code compiles
4. If there are errors, fix them and typecheck again
5. Use the format tool to clean up formatting
6. Output the final code

Guidelines:
- Use Eio for I/O when relevant (not Unix/Lwt)
- Prefer Result types over exceptions
- Add type annotations for public functions
- Include a brief module-level doc comment
- No unnecessary dependencies
|}
;;

(* ── Main ──────────────────────────────────────────────────── *)

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let output_file = ref None in
  let prompt_parts = ref [] in
  let rec parse = function
    | [] -> ()
    | "--file" :: path :: rest ->
      output_file := Some path;
      parse rest
    | s :: rest ->
      prompt_parts := s :: !prompt_parts;
      parse rest
  in
  parse args;
  let prompt = String.concat " " (List.rev !prompt_parts) in
  if prompt = ""
  then (
    Printf.eprintf
      "Usage: codegen_agent.exe [--file output.ml] \"description of code to generate\"\n";
    exit 1);
  let tools =
    match !output_file with
    | Some _ -> [ typecheck_tool; format_tool; write_file_tool ]
    | None -> [ typecheck_tool; format_tool ]
  in
  Eio_main.run
  @@ fun env ->
  let net = Eio.Stdenv.net env in
  Eio.Switch.run
  @@ fun sw ->
  let base_url =
    match Sys.getenv_opt "LLM_BASE_URL" with
    | Some url -> url
    | None -> "http://127.0.0.1:8085"
  in
  let provider_config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"qwen3.5"
      ~base_url
      ~api_key:""
      ~headers:[ "Content-Type", "application/json" ]
      ~request_path:"/v1/chat/completions"
      ()
  in
  let config =
    { (default_config ~model:"qwen3.5") with
      name = "codegen"
    ; system_prompt = Some system_prompt
    }
  in
  let options = { Agent.default_options with provider_config = Some provider_config } in
  let agent = Agent.create ~net ~config ~tools ~options () in
  let full_prompt =
    match !output_file with
    | Some path ->
      Printf.sprintf
        "%s\n\n\
         After generating and verifying the code, write it to %s using the write_file \
         tool."
        prompt
        path
    | None -> prompt
  in
  match Agent.run ~sw agent full_prompt with
  | Ok response ->
    List.iter
      (function
        | Text t ->
          print_string t;
          print_newline ()
        | _ -> ())
      response.content
  | Error e ->
    Printf.eprintf "Error: %s\n" (Error.to_string e);
    exit 1
;;
