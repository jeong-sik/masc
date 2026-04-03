(** Tests for prompt registry markdown sources and override API. *)

module Lib = Masc_mcp

let default_dir_permissions = 0o755

let test_dir () =
  let tmp = Filename.temp_file "masc_prompt_registry" "" in
  Sys.remove tmp;
  Unix.mkdir tmp default_dir_permissions;
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
  | "keeper.proactive_turn" ->
      ("test prompt for " ^ key,
       [ "idle_seconds"; "profile"; "goal"; "last_preview";
         "continuity_snapshot"; "seed" ])
  | "keeper.proactive_retry" ->
      ("test prompt for " ^ key, [ "attempt_phrase"; "reason"; "directive" ])
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
    ( "keeper.proactive_turn",
      "Turn {{idle_seconds}} {{profile}} {{goal}} {{last_preview}} {{continuity_snapshot}} {{seed}}" );
    ("keeper.proactive_retry", "Retry {{attempt_phrase}} {{reason}} {{directive}}");
    ("keeper.unified.system", "{{identity_header}}\n{{trait_lines}}{{instructions_block}}{{goal_lines}}");
    ("keeper.deliberation", "Keeper {{keeper_name}} {{soul_profile}} {{goal}} {{triggers}} {{world_state}}");
    ("governance.deliberation", "governance deliberation prompt");
    ("governance.dry_run", "DRY RUN governance prompt");
    ("dashboard.operator_judge", "operator facts {{facts_json}}");
    ("dashboard.governance_judge", "governance facts {{facts_json}}");
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

let with_clean_registry f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      cleanup_dir dir)
    (fun () -> f ~dir)

let fixture key =
  match List.assoc_opt key fixtures with
  | Some value -> value
  | None -> failwith ("missing fixture: " ^ key)

let make_entry ?(version = "1.0") ?(variables = []) ?metrics ?(deprecated = false)
    ?(created_at = 1234.0) id template =
  Prompt_registry.
    { id; template; version; variables; metrics; created_at; deprecated }

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
              check int "registered prompt count" 11 (List.length prompts));
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
                Prompt_registry.render_prompt_template "keeper.proactive_retry"
                  [
                    ("attempt_phrase", "previous attempt");
                    ("reason", "timeout");
                    ("directive", "now");
                  ]
              with
              | Ok rendered ->
                  check string "rendered markdown template"
                    "Retry previous attempt timeout now"
                    rendered
              | Error msg -> fail msg);
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
                Prompt_registry.set_override "keeper.proactive_retry"
                  "Retry {{attempt_phrase}} {{reason}} {{unknown}}"
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
      ( "versioned_registry",
        [
          test_case "version selection, counts, and explicit unregister work"
            `Quick (fun () ->
              with_clean_registry @@ fun ~dir:_ ->
              Prompt_registry.register
                (make_entry ~version:"1.0" "review.prompt" "v1 {{code}}");
              Prompt_registry.register
                (make_entry ~version:"2.0" "review.prompt" "v2 {{code}}");
              Prompt_registry.register
                (make_entry ~version:"1.0" "audit.prompt" "audit {{code}}");
              check int "count includes all registered versions" 3
                (Prompt_registry.count ());
              check int "unique ids count" 2 (Prompt_registry.count_unique ());
              check bool "id exists" true
                (Prompt_registry.exists ~id:"review.prompt" ());
              check bool "specific version exists" true
                (Prompt_registry.exists ~id:"review.prompt" ~version:"2.0" ());
              check int "versions listed" 2
                (List.length (Prompt_registry.get_versions ~id:"review.prompt" ()));
              check (list string) "list_ids includes prompt"
                [ "audit.prompt"; "review.prompt" ]
                (Prompt_registry.list_ids () |> List.sort String.compare);
              (match Prompt_registry.get ~id:"review.prompt" () with
              | Some entry -> check string "latest version chosen" "2.0" entry.version
              | None -> fail "missing latest prompt");
              check bool "unregister specific version" true
                (Prompt_registry.unregister ~id:"review.prompt" ~version:"2.0" ());
              (match Prompt_registry.get ~id:"review.prompt" () with
              | Some entry -> check string "fallback version remains" "1.0" entry.version
              | None -> fail "missing fallback prompt"));
          test_case "deprecate hides latest version from implicit get" `Quick
            (fun () ->
              with_clean_registry @@ fun ~dir:_ ->
              Prompt_registry.register
                (make_entry ~version:"1.0" "planner.prompt" "v1");
              Prompt_registry.register
                (make_entry ~version:"2.0" "planner.prompt" "v2");
              check bool "deprecate latest" true
                (Prompt_registry.deprecate ~id:"planner.prompt" ~version:"2.0" ());
              (match Prompt_registry.get ~id:"planner.prompt" () with
              | Some entry ->
                  check string "deprecated latest skipped" "1.0" entry.version
              | None -> fail "missing non-deprecated prompt");
              (match Prompt_registry.get ~id:"planner.prompt" ~version:"2.0" () with
              | Some entry -> check bool "explicit deprecated fetch" true entry.deprecated
              | None -> fail "missing deprecated prompt"));
          test_case "render uses registered versioned prompt templates" `Quick
            (fun () ->
              with_clean_registry @@ fun ~dir:_ ->
              Prompt_registry.register
                (make_entry ~version:"1.0" "render.prompt" "render {{subject}}");
              match
                Prompt_registry.render ~id:"render.prompt"
                  ~vars:[ ("subject", "coverage") ] ()
              with
              | Ok rendered ->
                  check string "rendered prompt" "render coverage" rendered
              | Error msg -> fail msg);
        ] );
      ( "stats_and_serialization",
        [
          test_case "update_metrics drives stats and averages" `Quick (fun () ->
              with_clean_registry @@ fun ~dir:_ ->
              Prompt_registry.register
                (make_entry ~version:"1.0" "alpha.prompt" "alpha");
              Prompt_registry.register
                (make_entry ~version:"1.0" "beta.prompt" "beta");
              Prompt_registry.update_metrics ~id:"alpha.prompt" ~version:"1.0"
                ~score:0.8 ();
              Prompt_registry.update_metrics ~id:"alpha.prompt" ~version:"1.0"
                ~score:0.4 ();
              Prompt_registry.update_metrics ~id:"beta.prompt" ~version:"1.0"
                ~score:1.0 ();
              Prompt_registry.update_metrics ~id:"beta.prompt" ~version:"1.0"
                ~score:0.6 ();
              let stats = Prompt_registry.stats () in
              check int "total prompts" 2 stats.total_prompts;
              check int "active prompts" 2 stats.active_prompts;
              check int "deprecated prompts" 0 stats.deprecated_prompts;
              check (option string) "most used remains deterministic in tie"
                (Some "alpha.prompt") stats.most_used;
              check (float 0.0001) "avg usage across prompts" 2.0 stats.avg_usage;
              match Prompt_registry.get ~id:"alpha.prompt" ~version:"1.0" () with
              | Some entry -> (
                  match entry.metrics with
                  | Some metrics ->
                      check int "usage_count" 2 metrics.usage_count;
                      check (float 0.0001) "avg_score" 0.6 metrics.avg_score
                  | None -> fail "missing metrics")
              | None -> fail "missing updated prompt");
          test_case "to_json and of_json roundtrip registered prompts" `Quick
            (fun () ->
              with_clean_registry @@ fun ~dir:_ ->
              Prompt_registry.register
                (make_entry ~version:"1.0" "roundtrip.a" "A");
              Prompt_registry.register
                (make_entry ~version:"2.0" "roundtrip.b" "B");
              let json = Prompt_registry.to_json () in
              Prompt_registry.clear ();
              match Prompt_registry.of_json json with
              | Ok imported ->
                  check int "imported entries" 2 imported;
                  check int "count after import" 2 (Prompt_registry.count ());
                  check bool "roundtrip prompt exists" true
                    (Prompt_registry.exists ~id:"roundtrip.b" ~version:"2.0" ())
              | Error msg -> fail msg);
          test_case "init reloads persisted prompt entries from disk" `Quick
            (fun () ->
              with_clean_registry @@ fun ~dir ->
              let persist_dir = Filename.concat dir "persisted" in
              Prompt_registry.init ~persist_dir ();
              Prompt_registry.register
                (make_entry ~version:"1.0" "persisted.prompt" "disk-backed");
              let persisted_path =
                Filename.concat persist_dir "persisted.prompt_1.0.json"
              in
              check bool "json persisted to disk" true
                (Sys.file_exists persisted_path);
              let persisted_json =
                persisted_path
                |> In_channel.with_open_text
                     (fun ic -> In_channel.input_all ic |> Yojson.Safe.from_string)
              in
              let stored_entry =
                match Prompt_registry.prompt_entry_of_yojson persisted_json with
                | Ok entry -> entry
                | Error msg -> fail msg
              in
              check string "persisted id" "persisted.prompt" stored_entry.id;
              check string "persisted template" "disk-backed" stored_entry.template;
              Prompt_registry.clear ();
              Prompt_registry.init ~persist_dir ();
              match Prompt_registry.get ~id:"persisted.prompt" ~version:"1.0" ()
              with
              | Some entry ->
                  check string "reloaded template" "disk-backed" entry.template
              | None -> fail "missing reloaded prompt");
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
      ( "validation_and_restore",
        [
          test_case "validate_prompt_templates reports unexpected variables"
            `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir ->
              write_file
                (Filename.concat prompts_dir "keeper.proactive_retry.md")
                (markdown_fixture "keeper.proactive_retry"
                   "Retry {{attempt_phrase}} {{reason}} {{unexpected_var}}");
              let issues = Prompt_registry.validate_prompt_templates () in
              check bool "unexpected variable flagged" true
                (List.mem ("keeper.proactive_retry", "unexpected_var") issues));
          test_case "persist_overrides and restore_overrides roundtrip valid entries"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper.world" "world override"
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              Prompt_registry.persist_overrides dir;
              Prompt_registry.clear_prompt_override "keeper.world";
              check string "cleared back to file" (fixture "keeper.world")
                (Prompt_registry.get_prompt "keeper.world");
              Prompt_registry.restore_overrides dir;
              check string "override restored" "world override"
                (Prompt_registry.get_prompt "keeper.world"));
          test_case "restore_overrides skips invalid entries and keeps valid ones"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir default_dir_permissions;
              write_file
                (Filename.concat masc_dir "prompt_overrides.json")
                (Yojson.Safe.pretty_to_string
                   (`Assoc
                     [
                       ("keeper.world", `String "restored world");
                       ( "keeper.proactive_retry",
                         `String
                           "Retry {{attempt_phrase}} {{reason}} {{unexpected_var}}" );
                     ]));
              Prompt_registry.restore_overrides dir;
              check string "valid override restored" "restored world"
                (Prompt_registry.get_prompt "keeper.world");
              check string "invalid override rejected" "file"
                (Prompt_registry.prompt_source "keeper.proactive_retry"));
        ] );
    ]
