(** Tests for prompt registry markdown sources and override API. *)

module Lib = Masc_mcp

let test_dir () =
  let tmp = Filename.temp_file "masc_prompt_registry" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let prompt_metadata key =
  match key with
  | "keeper.unified.system" ->
      ("test prompt for " ^ key,
       [ "identity_header"; "trait_lines"; "instructions_block"; "goal_lines" ])
  | "keeper.deliberation" ->
      ("test prompt for " ^ key,
       [ "keeper_name"; "soul_profile"; "goal"; "triggers"; "world_state" ])
  | "dashboard.operator_judge" | "dashboard.governance_judge" ->
      ("test prompt for " ^ key, [ "facts_json" ])
  | _ -> ("test prompt for " ^ key, [])

let markdown_fixture key body =
  let description, template_variables = prompt_metadata key in
  let meta_lines =
    [
      "---";
      "description: " ^ description;
      "category: test";
    ]
    @
    (if template_variables = [] then []
     else
       [
         "template_variables: ["
         ^ String.concat ", " template_variables
         ^ "]";
       ])
    @ [ "---" ]
  in
  String.concat "\n" (meta_lines @ [ body ])

let fixtures =
  [
    ("keeper.constitution", "Continuity rules from file");
    ("keeper.world", "MASC world from markdown");
    ("keeper.capabilities", "Capabilities from markdown");
    ("keeper.unified.system", "{{identity_header}}\n{{trait_lines}}{{instructions_block}}{{goal_lines}}");
    ("keeper.deliberation", "Keeper {{keeper_name}} {{soul_profile}} {{goal}} {{triggers}} {{world_state}}");
    ("governance.deliberation", "governance deliberation prompt");
    ("governance.dry_run", "DRY RUN governance prompt");
    ("dashboard.operator_judge", "operator facts {{facts_json}}");
    ("dashboard.governance_judge", "governance facts {{facts_json}}");
    ("test.unlisted.vars", "template body still has {{missing_var}}");
  ]

let with_registry f =
  let dir = test_dir () in
  let prompts_dir = Filename.concat dir "prompts" in
  Unix.mkdir prompts_dir 0o755;
  List.iter
    (fun (key, content) ->
      write_file
        (Filename.concat prompts_dir (key ^ ".md"))
        (markdown_fixture key content))
    fixtures;
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      cleanup_dir dir)
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir prompts_dir;
      Lib.Prompt_defaults.init ();
      f ~dir ~prompts_dir)

let fixture key =
  match List.assoc_opt key fixtures with
  | Some value -> value
  | None -> failwith ("missing fixture: " ^ key)

let get_string_field field = function
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`String value) -> Some value
      | _ -> None)
  | _ -> None

let get_bool_field field = function
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`Bool value) -> Some value
      | _ -> None)
  | _ -> None

let () =
  let open Alcotest in
  run "Prompt_registry_defaults"
    [
      ( "registration",
        [
          test_case "all markdown-backed prompts are registered" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              let prompts = Prompt_registry.list_prompts () in
              check int "registered prompt count" 10 (List.length prompts));
          test_case "get_prompt resolves markdown content" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "keeper.constitution"
                (fixture "keeper.constitution")
                (Prompt_registry.get_prompt "keeper.constitution");
              check string "governance.dry_run"
                (fixture "governance.dry_run")
                (Prompt_registry.get_prompt "governance.dry_run"));
          test_case "prompt_source reports file" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "file source" "file"
                (Prompt_registry.prompt_source "keeper.world"));
          test_case "validate_required_prompt_files detects missing file" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir ->
              Sys.remove
                (Filename.concat prompts_dir "dashboard.governance_judge.md");
              let missing = Prompt_registry.validate_required_prompt_files () in
              check bool "missing file found" true
                (List.mem_assoc "dashboard.governance_judge" missing));
        ] );
      ( "rendering",
        [
          test_case "render_prompt_template uses markdown template" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.render_prompt_template "keeper.unified.system"
                  [
                    ("identity_header", "TestKeeper");
                    ("trait_lines", "trait1");
                    ("instructions_block", "do things");
                    ("goal_lines", "goal1");
                  ]
              with
              | Ok rendered ->
                  check bool "rendered contains identity" true
                    (String.length rendered > 0
                     && (try ignore (Str.search_forward (Str.regexp_string "TestKeeper") rendered 0); true
                         with Not_found -> false))
              | Error msg -> fail msg);
          test_case "render_prompt_template leaves braces in values literal" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.render_prompt_template "dashboard.operator_judge"
                  [ ("facts_json", {|{"template":"{{ .Release.Name }}"}|}) ]
              with
              | Ok rendered ->
                  check bool "rendered keeps user braces" true
                    (try
                       ignore
                         (Str.search_forward
                            (Str.regexp_string "{{ .Release.Name }}")
                            rendered 0);
                       true
                     with Not_found -> false)
              | Error msg -> fail msg);
          test_case "render_prompt_template replaces whitespace placeholders" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir ->
              write_file
                (Filename.concat prompts_dir "test.unlisted.vars.md")
                (markdown_fixture "test.unlisted.vars" "hello {{ missing_var }}");
              match
                Prompt_registry.render_prompt_template "test.unlisted.vars"
                  [ (" missing_var ", "world") ]
              with
              | Ok rendered -> check string "rendered" "hello world" rendered
              | Error msg -> fail msg);
          test_case "render_prompt_template detects variables without metadata" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.render_prompt_template "test.unlisted.vars" []
              with
              | Error msg ->
                  check bool "reports unresolved variable" true
                    (try
                       ignore
                         (Str.search_forward
                            (Str.regexp_string "Unresolved variables")
                            msg 0);
                       true
                     with Not_found -> false)
              | Ok rendered ->
                  fail ("expected unresolved variable error, got: " ^ rendered));
          test_case "render_prompt_template validates effective template variables" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir ->
              write_file
                (Filename.concat prompts_dir "dashboard.operator_judge.md")
                (markdown_fixture "dashboard.operator_judge"
                   "operator facts {{runtime_only}}");
              match
                Prompt_registry.render_prompt_template "dashboard.operator_judge"
                  [ ("facts_json", "{}") ]
              with
              | Error msg ->
                  check bool "reports runtime-only variable" true
                    (try
                       ignore
                         (Str.search_forward
                            (Str.regexp_string "runtime_only")
                            msg 0);
                       true
                     with Not_found -> false)
              | Ok rendered ->
                  fail ("expected unresolved variable error, got: " ^ rendered));
        ] );
      ( "override",
        [
          test_case "set_override replaces file content" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              let override_text = "override constitution" in
              (match
                 Prompt_registry.set_override "keeper.constitution"
                   override_text
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              check string "override value" override_text
                (Prompt_registry.get_prompt "keeper.constitution");
              check string "override source" "override"
                (Prompt_registry.prompt_source "keeper.constitution"));
          test_case "clear_override reverts to file" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper.world"
                   "temporary override"
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              Prompt_registry.clear_prompt_override "keeper.world";
              check string "back to file baseline" (fixture "keeper.world")
                (Prompt_registry.get_prompt "keeper.world");
              check string "source is file" "file"
                (Prompt_registry.prompt_source "keeper.world"));
          test_case "set_override rejects unknown key" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match Prompt_registry.set_override "unknown.prompt" "x" with
              | Error _ -> ()
              | Ok () -> fail "should reject unknown prompt key");
          test_case "set_override rejects unknown template variable" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.set_override "keeper.deliberation"
                  "Keeper {{keeper_name}} {{soul_profile}} {{unknown}}"
              with
              | Error msg ->
                  check bool "mentions unknown variable" true
                    (try
                       ignore
                         (Str.search_forward
                            (Str.regexp_string "Unknown template variables")
                            msg 0);
                       true
                     with Not_found -> false)
              | Ok () -> fail "should reject unknown template variable");
        ] );
      ( "integration",
        [
          test_case "keeper_constitution reads markdown-backed registry" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "keeper constitution function"
                (fixture "keeper.constitution")
                (Lib.Keeper_prompt.keeper_constitution ()));
        ] );
      ( "prompts_json",
        [
          test_case "prompts_json exposes effective file and override fields" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper.capabilities"
                   "runtime override"
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              let json = Prompt_registry.prompts_json () in
              let open Yojson.Safe.Util in
              let prompts = json |> member "prompts" |> to_list in
              let keeper_capabilities =
                prompts
                |> List.find (fun item ->
                       get_string_field "key" item = Some "keeper.capabilities")
              in
              check (option string) "effective value"
                (Some "runtime override")
                (get_string_field "effective" keeper_capabilities);
              check (option string) "file value"
                (Some (fixture "keeper.capabilities"))
                (get_string_field "file_value" keeper_capabilities);
              check (option string) "override value"
                (Some "runtime override")
                (get_string_field "override_value" keeper_capabilities);
              check (option string) "source"
                (Some "override")
                (get_string_field "source" keeper_capabilities);
              check (option bool) "required_file"
                (Some true)
                (get_bool_field "required_file" keeper_capabilities);
              match keeper_capabilities with
              | `Assoc fields ->
                  check int "template_variables field exists" 0
                    (match List.assoc_opt "template_variables" fields with
                     | Some (`List items) -> List.length items
                     | _ -> -1)
              | _ -> fail "unexpected prompt JSON");
        ] );
    ]
