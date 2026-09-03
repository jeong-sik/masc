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
  | "test.render" ->
      ("test prompt for " ^ key,
       [ "identity_header"; "instructions_block"; "goal_lines" ])
  | "keeper.deliberation" ->
      ("test prompt for " ^ key,
       [ "keeper_name"; "soul_profile"; "goal"; "triggers"; "world_state" ])
  | "test.templated" ->
      ("test prompt for " ^ key, [ "facts_json" ])
  | "judge.board" ->
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
    (if String.equal key "test.plain" then [ "operator_surface: fragment" ]
     else [])
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

(* One fixture file per key: [with_registry] writes [<key>.md], so a repeated
   key would silently overwrite its own file and make [fixture] disagree with
   the registry. [test_fixture_keys_are_unique] pins that. *)
let fixtures =
  [
    ("keeper", "Keeper system contract from file");
    ("keeper.reply_guidelines", "Reply guidelines from markdown");
    ("test.render", "{{identity_header}}\n{{instructions_block}}{{goal_lines}}");
    ("keeper.deliberation", "Keeper {{keeper_name}} {{soul_profile}} {{goal}} {{triggers}} {{world_state}}");
    ("test.plain", "plain body, no template variables");
    ("test.templated", "templated body {{facts_json}}");
    ( "judge.board"
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

(* ── Fragment-group slots (#32780) ────────────────────────────────────

   A group file registers each [### marker] paragraph as
   <group>.<marker>; the group key itself stays unregistered. Variables
   declared on the marker line become the slot's template_variables, so
   per-slot validation keeps its old strength despite the merge. *)
let test_fragment_group_slots () =
  let open Alcotest in
  let dir = test_dir () in
  let prompts_dir = Filename.concat dir "prompts" in
  Unix.mkdir prompts_dir 0o755;
  write_file
    (Filename.concat prompts_dir "test.group.md")
    {|
---
description: group fragments for the slot test
category: test
---
### standing.current (vars: target, behind)
At {{target}}, even with {{behind}} behind.

### standing.diverged
Diverged; no numbers.
|};
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      cleanup_dir dir)
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir prompts_dir;
      Lib.Prompt_defaults.init ();
      check string "slot value is its paragraph"
        "Diverged; no numbers."
        (Prompt_registry.get_prompt "test.group.standing.diverged");
      check bool "slot value omits the marker line"
        (not
           (String.contains
              (Prompt_registry.get_prompt "test.group.standing.diverged")
              '#'))
        true;
      (match
         Prompt_registry.render_prompt_template "test.group.standing.current"
           [ ("target", "T"); ("behind", "2") ]
       with
      | Ok rendered ->
        check string "slot renders its variables" "At T, even with 2 behind."
          rendered
      | Error message -> fail ("render failed: " ^ message));
      check string "group key is not registered" ""
        (Prompt_registry.get_prompt "test.group"))
;;

let () =
  let open Alcotest in
  run "Prompt_registry_defaults"
    [
      ( "fragment_group_slots",
        [ test_case "slots register, render, and leave the group key unregistered"
            `Quick test_fragment_group_slots ] );
      ( "registration",
        [
          (* Guards the count assertion below: a bulk key rename that maps two
             fixtures onto one key writes one file, and "registered prompt
             count" would then fail with an unrelated-looking off-by-one while
             [fixture key] silently returned the shadowed body. *)
          test_case "fixture keys are unique" `Quick (fun () ->
              let keys = List.map fst fixtures in
              check int "one fixture per key"
                (List.length keys)
                (List.length (List.sort_uniq String.compare keys)));
          test_case "all markdown-backed prompts are registered" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              let prompts = Prompt_registry.list_prompts () in
              check int
                "registered prompt count"
                (List.length fixtures)
                (List.length prompts));
          test_case "get_prompt resolves markdown content" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "keeper"
                (fixture "keeper")
                (Prompt_registry.get_prompt "keeper");
              check string "test.plain"
                (fixture "test.plain")
                (Prompt_registry.get_prompt "test.plain"));
          test_case "prompt_source reports file" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "file source" "file"
                (Prompt_registry.prompt_source "keeper.reply_guidelines"));
        ] );
      ( "rendering",
        [
          test_case "render_prompt_template uses markdown template" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.render_prompt_template "test.render"
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
          test_case "resolve and render returns the exact source snapshot" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.resolve_and_render_prompt_template "test.render"
                  [
                    ("identity_header", "TestKeeper");
                    ("instructions_block", "do things");
                    ("goal_lines", "goal1");
                  ]
              with
              | Ok (resolution, rendered) ->
                  check string "source" "file" resolution.source;
                  check string "rendered from returned template"
                    rendered
                    (match
                       Prompt_registry.render_prompt_template "test.render"
                         [
                           ("identity_header", "TestKeeper");
                           ("instructions_block", "do things");
                           ("goal_lines", "goal1");
                         ]
                     with
                     | Ok value -> value
                     | Error msg -> fail msg)
              | Error msg -> fail msg);
          test_case "render_prompt_template leaves braces in values literal" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.render_prompt_template "test.templated"
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
                (Filename.concat prompts_dir "test.templated.md")
                (markdown_fixture "test.templated"
                   "Gate facts {{runtime_only}}");
              match
                Prompt_registry.render_prompt_template "test.templated"
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
              let override_text = "override the shared system contract" in
              (match
                 Prompt_registry.set_override "keeper"
                   override_text
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              check string "override value" override_text
                (Prompt_registry.get_prompt "keeper");
              check string "override source" "override"
                (Prompt_registry.prompt_source "keeper"));
          test_case "clear_override reverts to file" `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper.reply_guidelines"
                   "temporary override"
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              Prompt_registry.clear_prompt_override "keeper.reply_guidelines";
              check string "back to file baseline" (fixture "keeper.reply_guidelines")
                (Prompt_registry.get_prompt "keeper.reply_guidelines");
              check string "source is file" "file"
                (Prompt_registry.prompt_source "keeper.reply_guidelines"));
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
            "invalid persisted override object is rejected observably"
            `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper"
                   "pre-existing live override"
               with
              | Ok () -> ()
              | Error message -> fail message);
              let before = override_restore_failure_count () in
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir 0o755;
              write_file
                (prompt_overrides_path dir)
                {|{"unexpected":"value"}|};
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "restore rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "invalid override not applied"
                (fixture "keeper")
                (Prompt_registry.get_prompt "keeper"));
          test_case "matching contract revision round-trips and applies" `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir ->
              let override_text = "persisted system contract override" in
              (match
                 Prompt_registry.set_override "keeper"
                   override_text
               with
              | Ok () -> ()
              | Error message -> fail message);
              persist_overrides_or_fail dir;
              reload_registry prompts_dir;
              Prompt_registry.restore_overrides dir;
              check string "matching override restored" override_text
                (Prompt_registry.get_prompt "keeper");
              check string "matching override source" "override"
                (Prompt_registry.prompt_source "keeper"));
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
                 Prompt_registry.set_override "keeper.reply_guidelines"
                   "persisted reply-guidelines override"
               with
              | Ok () -> ()
              | Error message -> fail message);
              persist_overrides_or_fail dir;
              reload_registry prompts_dir;
              let changed_body = "Reply guidelines contract changed" in
              write_file
                (Filename.concat prompts_dir "keeper.reply_guidelines.md")
                (markdown_fixture "keeper.reply_guidelines" changed_body);
              reload_registry prompts_dir;
              let before = override_restore_failure_count () in
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "body drift rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "body drift falls back to changed file" changed_body
                (Prompt_registry.get_prompt "keeper.reply_guidelines");
              check string "body drift source" "file"
                (Prompt_registry.prompt_source "keeper.reply_guidelines"));
          test_case
            "template-variable drift invalidates persisted override"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir ->
              (match
                 Prompt_registry.set_override "test.templated"
                   "persisted facts {{facts_json}}"
               with
              | Ok () -> ()
              | Error message -> fail message);
              persist_overrides_or_fail dir;
              let body = fixture "test.templated" in
              write_file
                (Filename.concat prompts_dir "test.templated.md")
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
                (Prompt_registry.get_prompt "test.templated");
              check string "variable drift source" "file"
                (Prompt_registry.prompt_source "test.templated"));
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
                    {|{"schema_version":1,"overrides":[{"key":"keeper.reply_guidelines","value":42,"contract_revision":"r"}]}|}
                  );
                  ( "duplicate entry field",
                    {|{"schema_version":1,"overrides":[{"key":"keeper.reply_guidelines","key":"keeper","value":"x","contract_revision":"r"}]}|}
                  );
                  ( "duplicate override key",
                    {|{"schema_version":1,"overrides":[{"key":"keeper.reply_guidelines","value":"x","contract_revision":"r"},{"key":"keeper.reply_guidelines","value":"y","contract_revision":"r"}]}|}
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
                  check string (name ^ " fallback") (fixture "keeper.reply_guidelines")
                    (Prompt_registry.get_prompt "keeper.reply_guidelines"))
                malformed);
          test_case
            "persisted set and clear leave live state unchanged on write failure"
            `Quick
            (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let old_value = "pre-existing override" in
              (match Prompt_registry.set_override "keeper.reply_guidelines" old_value with
               | Ok () -> ()
               | Error message -> fail message);
              write_file (Filename.concat dir ".masc") "not a directory";
              (match
                 Prompt_registry.set_override_persisted ~base_path:dir
                   "keeper.reply_guidelines" "new override"
               with
              | Error (Prompt_registry.Persistence_error _) -> ()
              | Error (Prompt_registry.Validation_error message) ->
                  fail ("unexpected validation failure: " ^ message)
              | Ok () -> fail "failed persisted set must not report success");
              check string "failed set preserves live value" old_value
                (Prompt_registry.get_prompt "keeper.reply_guidelines");
              (match
                 Prompt_registry.clear_prompt_override_persisted ~base_path:dir
                   "keeper.reply_guidelines"
               with
              | Error _ -> ()
              | Ok () -> fail "failed persisted clear must not report success");
              check string "failed clear preserves live value" old_value
                (Prompt_registry.get_prompt "keeper.reply_guidelines"));
          test_case
            "set_override rejects placeholder syntax on a prompt with no \
             declared template_variables"
            `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              (* [keeper] declares an exact empty variable set, so any
                 placeholder is invalid. *)
              match
                Prompt_registry.set_override "keeper"
                  "Rules {{undeclared_variable}} more text"
              with
              | Error msg ->
                  check bool "mentions the stray placeholder" true
                    (try
                       ignore
                         (Str.search_forward
                            (Str.regexp_string "undeclared_variable")
                            msg 0);
                       true
                     with Not_found -> false)
              | Ok () ->
                  fail
                    "should reject {{placeholder}} syntax when no \
                     template_variables are declared");
          test_case
            "set_override rejects placeholder syntax on any zero-variable \
             prompt, not just keeper"
            `Quick (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              match
                Prompt_registry.set_override "keeper.reply_guidelines"
                  "{{unexpected}} reply-guidelines override"
              with
              | Error _ -> ()
              | Ok () ->
                  fail
                    "should reject {{placeholder}} syntax for keeper.reply_guidelines \
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
                {|{"keeper":"Rules {{undeclared_variable}}"}|};
              Prompt_registry.restore_overrides dir;
              check (float 0.0001) "restore rejection counted"
                (before +. 1.0)
                (override_restore_failure_count ());
              check string "stale placeholder override not applied"
                (fixture "keeper")
                (Prompt_registry.get_prompt "keeper");
              check string "source falls back to file" "file"
                (Prompt_registry.prompt_source "keeper"));
        ] );
      ( "integration",
        [
          test_case "system_prompt_body reads markdown-backed registry" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              check string "keeper system function"
                (fixture "keeper")
                (Lib.Keeper_prompt.system_prompt_body ()));
          test_case
            "system_prompt_body falls back to file when a persisted \
             override contains an undeclared placeholder"
            `Quick (fun () ->
              with_registry @@ fun ~dir ~prompts_dir:_ ->
              let masc_dir = Filename.concat dir ".masc" in
              Unix.mkdir masc_dir 0o755;
              write_file
                (prompt_overrides_path dir)
                {|{"keeper":"Rules {{undeclared_variable}}"}|};
              Prompt_registry.restore_overrides dir;
              check string "system_prompt_body ignores the rejected override"
                (fixture "keeper")
                (Lib.Keeper_prompt.system_prompt_body ()));
        ] );
      ( "prompts_json",
        [
          test_case "prompts_json exposes effective file and override fields" `Quick
            (fun () ->
              with_registry @@ fun ~dir:_ ~prompts_dir:_ ->
              (match
                 Prompt_registry.set_override "keeper"
                   "runtime override"
               with
              | Ok () -> ()
              | Error msg -> fail msg);
              let json = Prompt_registry.prompts_json () in
              let open Yojson.Safe.Util in
              let prompts = json |> member "prompts" |> to_list in
              let keeper_system =
                prompts
                |> List.find (fun item ->
                       get_string_field "key" item = Some "keeper")
              in
              check (option string) "effective value"
                (Some "runtime override")
                (get_string_field "effective" keeper_system);
              check (option string) "file value"
                (Some (fixture "keeper"))
                (get_string_field "file_value" keeper_system);
              check (option string) "override value"
                (Some "runtime override")
                (get_string_field "override_value" keeper_system);
              check (option string) "source"
                (Some "override")
                (get_string_field "source" keeper_system);
              check (option string) "legacy metadata stays operator-visible"
                (Some "primary")
                (get_string_field "operator_surface" keeper_system);
              let fragment =
                prompts
                |> List.find (fun item ->
                       get_string_field "key" item = Some "test.plain")
              in
              check (option string) "frontmatter exposes assembly fragments"
                (Some "fragment")
                (get_string_field "operator_surface" fragment);
              check (option bool) "required_file"
                (Some true)
                (get_bool_field "required_file" keeper_system);
              match keeper_system with
              | `Assoc fields ->
                  check int "template_variables field exists" 0
                    (match List.assoc_opt "template_variables" fields with
                     | Some (`List items) -> List.length items
                     | _ -> -1)
              | _ -> fail "unexpected prompt JSON");
        ] );
    ]

