(** Tests for prompt registry markdown sources and override API. *)

module Lib = Masc

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
       [ "identity_header"; "instructions_block"; "goal_lines" ])
  | "keeper.deliberation" ->
      ("test prompt for " ^ key,
       [ "keeper_name"; "soul_profile"; "goal"; "triggers"; "world_state" ])
  | "dashboard.operator_judge"
  | "dashboard.gate_judge" ->
      ("test prompt for " ^ key, [ "facts_json" ])
  | "keeper.board_attention_judgment" ->
      ("test prompt for " ^ key, [ "judgment_request_json" ])
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
    ("keeper.unified.system", "{{identity_header}}\n{{instructions_block}}{{goal_lines}}");
    ("keeper.deliberation", "Keeper {{keeper_name}} {{soul_profile}} {{goal}} {{triggers}} {{world_state}}");
    ("deliberation.decision", "structured deliberation prompt");
    ("analysis.dry_run", "DRY RUN analysis prompt");
    ("dashboard.operator_judge", "operator facts {{facts_json}}");
    ("dashboard.gate_judge", "Gate facts {{facts_json}}");
    ( "keeper.board_attention_judgment"
    , "Board attention {{judgment_request_json}}" );
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

let prompt_overrides_path dir =
  Filename.concat (Filename.concat dir ".masc") "prompt_overrides.json"

let reload_registry prompts_dir =
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir prompts_dir;
  Lib.Prompt_defaults.init ()

let persist_overrides_or_fail dir =
  match Prompt_registry.persist_overrides dir with
  | Ok () -> ()
  | Error message -> failwith message

let override_restore_failure_count () =
  Lib.Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string PromptFailures)
    ~labels:[ ("prompt", "override_restore") ]
    ()

let () =
  let open Alcotest in
  run "Prompt_registry_defaults"
    [
      ( "registration",
        [
          test_case "all markdown-backed prompts are registered" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              let prompts = Prompt_registry.list_prompts () in
              check int
                "registered prompt count"
                (List.length fixtures)
                (List.length prompts));
          test_case "get_prompt resolves markdown content" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "keeper.constitution"
                (fixture "keeper.constitution")
                (Prompt_registry.get_prompt "keeper.constitution");
              check string "analysis.dry_run"
                (fixture "analysis.dry_run")
                (Prompt_registry.get_prompt "analysis.dry_run"));
          test_case "prompt_source reports file" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "file source" "file"
                (Prompt_registry.prompt_source "keeper.world"));
          test_case "validate_required_prompt_files detects missing file" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir ->
              Sys.remove (Filename.concat prompts_dir "dashboard.gate_judge.md");
              let missing = Prompt_registry.validate_required_prompt_files () in
              check bool "missing file found" true
                (List.mem_assoc "dashboard.gate_judge" missing));
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
          test_case
            "legacy bare STATE/NEXT/BDI override map is rejected observably"
            `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper.constitution"
                   "pre-existing live override"
               with
              | Ok () -> ()
              | Error message -> fail message);
              let before = override_restore_failure_count () in
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir 0o755;
              write_file
                (prompt_overrides_path dir)
                {|{"keeper.constitution":"[STATE] NEXT Constraints BDI"}|};
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "restore rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "legacy override not applied"
                (fixture "keeper.constitution")
                (Prompt_registry.get_prompt "keeper.constitution"));
          test_case "matching contract revision round-trips and applies" `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir ->
              let override_text = "persisted constitution override" in
              (match
                 Prompt_registry.set_override "keeper.constitution"
                   override_text
               with
              | Ok () -> ()
              | Error message -> fail message);
              persist_overrides_or_fail dir;
              reload_registry prompts_dir;
              Prompt_registry.restore_overrides dir;
              check string "matching override restored" override_text
                (Prompt_registry.get_prompt "keeper.constitution");
              check string "matching override source" "override"
                (Prompt_registry.prompt_source "keeper.constitution"));
          test_case "contract revision canonicalizes variable ordering" `Quick
            (fun () ->
              let left =
                Prompt_override_persistence.contract_revision ~body:"body"
                  ~template_variables:[ "zeta"; "alpha" ]
              in
              let right =
                Prompt_override_persistence.contract_revision ~body:"body"
                  ~template_variables:[ "alpha"; "zeta" ]
              in
              check string "sorted variables have one revision" left right);
          test_case "markdown body drift invalidates persisted override" `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir ->
              (match
                 Prompt_registry.set_override "keeper.world"
                   "persisted world override"
               with
              | Ok () -> ()
              | Error message -> fail message);
              persist_overrides_or_fail dir;
              reload_registry prompts_dir;
              let changed_body = "MASC world contract changed" in
              write_file
                (Filename.concat prompts_dir "keeper.world.md")
                (markdown_fixture "keeper.world" changed_body);
              reload_registry prompts_dir;
              let before = override_restore_failure_count () in
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "body drift rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "body drift falls back to changed file" changed_body
                (Prompt_registry.get_prompt "keeper.world");
              check string "body drift source" "file"
                (Prompt_registry.prompt_source "keeper.world"));
          test_case
            "template-variable drift invalidates persisted override"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir ->
              (match
                 Prompt_registry.set_override "dashboard.operator_judge"
                   "persisted facts {{facts_json}}"
               with
              | Ok () -> ()
              | Error message -> fail message);
              persist_overrides_or_fail dir;
              let body = fixture "dashboard.operator_judge" in
              write_file
                (Filename.concat prompts_dir "dashboard.operator_judge.md")
                (String.concat "\n"
                   [
                     "---";
                     "description: changed variable contract";
                     "category: test";
                     "template_variables: [facts_json, additional_context]";
                     "---";
                     body;
                   ]);
              reload_registry prompts_dir;
              let before = override_restore_failure_count () in
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "variable drift rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "variable drift falls back to file" body
                (Prompt_registry.get_prompt "dashboard.operator_judge");
              check string "variable drift source" "file"
                (Prompt_registry.prompt_source "dashboard.operator_judge"));
          test_case "malformed versioned envelopes fail closed observably" `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir 0o755;
              let malformed =
                [
                  ("wrong schema", {|{"schema_version":2,"overrides":[]}|});
                  ("top-level array", {|[]|});
                  ( "non-string value",
                    {|{"schema_version":1,"overrides":[{"key":"keeper.world","value":42,"contract_revision":"r"}]}|}
                  );
                  ( "duplicate entry field",
                    {|{"schema_version":1,"overrides":[{"key":"keeper.world","key":"keeper.constitution","value":"x","contract_revision":"r"}]}|}
                  );
                  ( "duplicate override key",
                    {|{"schema_version":1,"overrides":[{"key":"keeper.world","value":"x","contract_revision":"r"},{"key":"keeper.world","value":"y","contract_revision":"r"}]}|}
                  );
                  ("invalid JSON", {|{"schema_version":1|});
                ]
              in
              List.iter
                (fun (name, content) ->
                  write_file (prompt_overrides_path dir) content;
                  let before = override_restore_failure_count () in
                  Prompt_registry.restore_overrides dir;
                  check (float 0.0001) (name ^ " rejection counted")
                    (before +. 1.0)
                    (override_restore_failure_count ());
                  check string (name ^ " fallback") (fixture "keeper.world")
                    (Prompt_registry.get_prompt "keeper.world"))
                malformed);
          test_case
            "persisted set and clear leave live state unchanged on write failure"
            `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let old_value = "pre-existing override" in
              (match Prompt_registry.set_override "keeper.world" old_value with
               | Ok () -> ()
               | Error message -> fail message);
              write_file (Filename.concat dir ".masc") "not a directory";
              (match
                 Prompt_registry.set_override_persisted ~base_path:dir
                   "keeper.world" "new override"
               with
              | Error (Prompt_registry.Persistence_error _) -> ()
              | Error (Prompt_registry.Validation_error message) ->
                  fail ("unexpected validation failure: " ^ message)
              | Ok () -> fail "failed persisted set must not report success");
              check string "failed set preserves live value" old_value
                (Prompt_registry.get_prompt "keeper.world");
              (match
                 Prompt_registry.clear_prompt_override_persisted ~base_path:dir
                   "keeper.world"
               with
              | Error _ -> ()
              | Ok () -> fail "failed persisted clear must not report success");
              check string "failed clear preserves live value" old_value
                (Prompt_registry.get_prompt "keeper.world"));
          test_case
            "set_override rejects placeholder syntax on a prompt with no \
             declared template_variables"
            `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              (* keeper.constitution has no template_variables, matching
                 config/prompts/keeper.constitution.md after masc#23929
                 dropped [template_variables: [state_block_instruction]]
                 along with the retired STATE-block protocol. A restored
                 legacy override still carrying that placeholder syntax
                 must not be treated as "no variables declared, anything
                 goes". *)
              match
                Prompt_registry.set_override "keeper.constitution"
                  "Legacy rules {{state_block_instruction}} more text"
              with
              | Error msg ->
                  check bool "mentions the stray placeholder" true
                    (try
                       ignore
                         (Str.search_forward
                            (Str.regexp_string "state_block_instruction")
                            msg 0);
                       true
                     with Not_found -> false)
              | Ok () ->
                  fail
                    "should reject {{placeholder}} syntax when no \
                     template_variables are declared");
          test_case
            "set_override rejects placeholder syntax on any zero-variable \
             prompt, not just keeper.constitution"
            `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.set_override "keeper.world"
                  "{{unexpected}} world override"
              with
              | Error _ -> ()
              | Ok () ->
                  fail
                    "should reject {{placeholder}} syntax for keeper.world \
                     too");
          test_case
            "restore_overrides rejects a persisted placeholder override and \
             falls back to the file baseline"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let before = override_restore_failure_count () in
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir 0o755;
              write_file
                (prompt_overrides_path dir)
                {|{"keeper.constitution":"Legacy STATE rules {{state_block_instruction}}"}|};
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "restore rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "stale placeholder override not applied"
                (fixture "keeper.constitution")
                (Prompt_registry.get_prompt "keeper.constitution");
              check string "source falls back to file" "file"
                (Prompt_registry.prompt_source "keeper.constitution"));
        ] );
      ( "integration",
        [
          test_case "keeper_constitution reads markdown-backed registry" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "keeper constitution function"
                (fixture "keeper.constitution")
                (Lib.Keeper_prompt.keeper_constitution ()));
          test_case
            "keeper_constitution falls back to file when a persisted \
             override still carries the retired {{state_block_instruction}} \
             placeholder"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir 0o755;
              write_file
                (prompt_overrides_path dir)
                {|{"keeper.constitution":"Legacy STATE rules {{state_block_instruction}}"}|};
              Prompt_registry.restore_overrides dir;
              check string "keeper_constitution ignores the rejected override"
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
