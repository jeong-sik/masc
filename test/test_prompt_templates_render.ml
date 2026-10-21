(** Every prompt shipped in [config/prompts] renders with the variables its own
    frontmatter declares.

    Two layers made a broken prompt survive silently. [get_prompt] answers the
    empty string for a key it cannot find, and the startup check
    ([Server_runtime_bootstrap], via [validate_prompt_templates]) logs an error
    and boots anyway. So a renamed file, a placeholder the frontmatter does not
    declare, or a declared variable the template never uses shipped as a
    quietly shorter prompt — the model simply received less instruction, and no
    test or boot failure said so.

    This makes the whole prompt directory a CI gate instead: every key resolves,
    every declared variable is consumed, and every placeholder in the body is
    declared. *)

open Alcotest

let prompt_dir () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> Filename.concat root "config/prompts"
  | None -> Filename.concat (Sys.getcwd ()) "config/prompts"
;;

let load () =
  Prompt_registry.set_markdown_dir (prompt_dir ());
  Masc.Prompt_defaults.init ()
;;

(* A value distinctive enough that finding it proves the template placed this
   variable, rather than the word appearing in the template's own prose. *)
let marker name = Printf.sprintf "@@VAR_%s@@" name

let key_and_variables item =
  match item with
  | `Assoc fields ->
    let key =
      match List.assoc_opt "key" fields with
      | Some (`String key) -> key
      | _ -> failf "prompt listing entry has no key: %s" (Yojson.Safe.to_string item)
    in
    let variables =
      match List.assoc_opt "template_variables" fields with
      | Some (`List values) ->
        List.filter_map
          (function
            | `String name -> Some name
            | _ -> None)
          values
      | _ -> []
    in
    (key, variables)
  | other -> failf "prompt listing entry is not an object: %s" (Yojson.Safe.to_string other)
;;

let test_every_prompt_renders () =
  load ();
  let prompts = Prompt_registry.list_prompts () in
  check bool "the prompt directory is not empty" true (prompts <> []);
  List.iter
    (fun item ->
       let key, variables = key_and_variables item in
       check
         bool
         (key ^ ": resolves from a real source")
         true
         (match Prompt_registry.prompt_source key with
          | Prompt_registry.Missing -> false
          | Prompt_registry.Override | Prompt_registry.File -> true);
       let vars = List.map (fun name -> (name, marker name)) variables in
       match Prompt_registry.render_prompt_template key vars with
       | Error detail -> failf "%s: does not render: %s" key detail
       | Ok text ->
         (* A variable the frontmatter declares and the body never uses is the
            shape that let a computed section vanish: the caller keeps building
            it and the template keeps ignoring it. *)
         List.iter
           (fun name ->
              check
                bool
                (Printf.sprintf "%s: declared variable %s is used by the body" key name)
                true
                (Astring.String.is_infix ~affix:(marker name) text))
           variables)
    prompts
;;

(* Same invariant the boot gate enforces, decided here instead of at the first
   start after a release: every prompt markdown file the repo ships registers as
   a key. A file the loader skipped — unreadable, or with frontmatter it could
   not parse — otherwise becomes a prompt nobody notices is gone, because the
   only symptom is a shorter prompt. *)
let test_every_prompt_file_registers () =
  load ();
  let dir = prompt_dir () in
  let files =
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".md")
    |> List.sort String.compare
  in
  check bool "the prompt directory ships markdown" true (files <> []);
  List.iter
    (fun file ->
       let key = Filename.remove_extension file in
       check
         bool
         (file ^ ": registers as key " ^ key)
         true
         (match Prompt_registry.prompt_source key with
          | Prompt_registry.Missing -> false
          | Prompt_registry.Override | Prompt_registry.File -> true))
    files
;;

let test_no_template_uses_an_undeclared_variable () =
  load ();
  match Prompt_registry.validate_prompt_templates () with
  | [] -> ()
  | invalid ->
    failf
      "templates use variables their frontmatter does not declare: %s"
      (invalid
       |> List.map (fun (key, variable) -> Printf.sprintf "%s -> %s" key variable)
       |> String.concat ", ")
;;


(* Overrides must reach consumers after bootstrap, while an existing tool keeps
   the immutable schema with which it was constructed. This exercises registry
   mutation and actual tool constructors, rather than pinning prompt wording. *)
let test_agent_core_overrides_reach_new_consumers () =
  load ();
  let module Core = Agent_core in
  let keys =
    [ "agent_core.unknown_tool.not_bare"
    ; "agent_core.handoff.prompt_param_description"
    ; "agent_core.agent_tool.prompt_param_description"
    ]
  in
  let prompt_description (tool : Core.Tool.t) =
    match tool.schema.parameters with
    | [ parameter ] -> parameter.Core.Types.description
    | _ -> fail "expected one prompt parameter"
  in
  let make_handoff () =
    Core.Handoff.make_handoff_tool
      ~delegate:(fun _ -> Error { Core.Types.message = "not executed"; recoverable = false; error_class = None })
      { Core.Handoff.name = "delegate"
      ; description = "test target"
      ; config = Core.Types.default_config ~model:"test-model"
      ; tools = []
      }
  in
  let make_agent_tool () =
    Core.Agent_tool.create_simple ~name:"child" ~description:"test child"
      (fun _ -> Error (Core.Error.Internal "not executed"))
  in
  let original_unknown = (Core.Tool_guidance_text.current ()).unknown_tool_not_bare () in
  let old_handoff = make_handoff () in
  let old_agent_tool = make_agent_tool () in
  let original_handoff = prompt_description old_handoff in
  let original_agent_tool = prompt_description old_agent_tool in
  Fun.protect
    ~finally:(fun () -> List.iter Prompt_registry.clear_prompt_override keys)
    (fun () ->
      List.iteri
        (fun index key ->
          match Prompt_registry.set_override key (Printf.sprintf "updated-%d" index) with
          | Ok () -> ()
          | Error detail -> failf "%s: %s" key detail)
        keys;
      check string "unknown-tool guidance resolves the new override"
        "updated-0" ((Core.Tool_guidance_text.current ()).unknown_tool_not_bare ());
      check string "new handoff resolves the new override"
        "updated-1" (prompt_description (make_handoff ()));
      check string "new agent tool resolves the new override"
        "updated-2" (prompt_description (make_agent_tool ()));
      check string "existing handoff schema stays unchanged"
        original_handoff (prompt_description old_handoff);
      check string "existing agent-tool schema stays unchanged"
        original_agent_tool (prompt_description old_agent_tool);
      List.iter Prompt_registry.clear_prompt_override keys;
      check string "clearing an override restores unknown-tool guidance"
        original_unknown ((Core.Tool_guidance_text.current ()).unknown_tool_not_bare ());
      check string "clearing an override restores new handoff schemas"
        original_handoff (prompt_description (make_handoff ()));
      check string "clearing an override restores new agent-tool schemas"
        original_agent_tool (prompt_description (make_agent_tool ())))
;;

let () =
  Alcotest.run
    "prompt_templates"
    [ ( "config/prompts"
      , [ test_case
            "every prompt renders and consumes what it declares"
            `Quick
            test_every_prompt_renders
        ; test_case
            "no template uses an undeclared variable"
            `Quick
            test_no_template_uses_an_undeclared_variable
        ; test_case
            "AgentCore overrides reach new consumers after bootstrap"
            `Quick
            test_agent_core_overrides_reach_new_consumers
        ; test_case
            "every prompt file registers as a key"
            `Quick
            test_every_prompt_file_registers
        ] )
    ]
;;
