open Agent_sdk

let () =
  let open Alcotest in
  run
    "Skill"
    [ ( "frontmatter"
      , [ test_case "parse basic frontmatter" `Quick (fun () ->
            let md = "---\nname: greet\ndescription: Say hello\n---\nHello $ARGUMENTS" in
            let skill = Skill.of_markdown md in
            check string "name" "greet" skill.name;
            check (option string) "description" (Some "Say hello") skill.description;
            check string "body" "Hello $ARGUMENTS" skill.body)
        ; test_case "no frontmatter" `Quick (fun () ->
            let md = "Just a body with no frontmatter." in
            let skill = Skill.of_markdown md in
            check string "name" "skill" skill.name;
            check (option string) "description" None skill.description;
            check string "body" "Just a body with no frontmatter." skill.body)
        ; test_case "name from path" `Quick (fun () ->
            let skill = Skill.of_markdown ~path:"/skills/review.md" "body" in
            check string "name" "review" skill.name)
        ; test_case "scope from frontmatter" `Quick (fun () ->
            let md = "---\nscope: project\n---\nbody" in
            let skill = Skill.of_markdown md in
            check bool "is project" true (skill.scope = Some Skill.Project))
        ; test_case "scope from parameter" `Quick (fun () ->
            let skill = Skill.of_markdown ~scope:Skill.User "body" in
            check bool "is user" true (skill.scope = Some Skill.User))
        ; test_case "allowed_tools csv" `Quick (fun () ->
            let md = "---\nallowed-tools: Read, Write, Bash\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (list string) "tools" [ "Read"; "Write"; "Bash" ] skill.allowed_tools)
        ; test_case "allowed_tools list syntax" `Quick (fun () ->
            let md = "---\nallowed_tools:\n- Read\n- Edit\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (list string) "tools" [ "Read"; "Edit" ] skill.allowed_tools)
        ] )
    ; ( "render"
      , [ test_case "no arguments" `Quick (fun () ->
            let skill = Skill.of_markdown "Hello world" in
            check string "rendered" "Hello world" (Skill.render_prompt skill))
        ; test_case "replace $ARGUMENTS" `Quick (fun () ->
            let skill = Skill.of_markdown "Review $ARGUMENTS please" in
            check
              string
              "rendered"
              "Review PR #42 please"
              (Skill.render_prompt ~arguments:"PR #42" skill))
        ; test_case "replace {{arguments}}" `Quick (fun () ->
            let skill = Skill.of_markdown "Fix {{arguments}} now" in
            check
              string
              "rendered"
              "Fix the bug now"
              (Skill.render_prompt ~arguments:"the bug" skill))
        ] )
    ; ( "supporting_files"
      , [ test_case "relative paths resolved" `Quick (fun () ->
            let md = "---\nsupporting-files: utils.py, lib/helper.py\n---\nbody" in
            let skill = Skill.of_markdown ~path:"/project/skills/review.md" md in
            let paths = Skill.supporting_file_paths skill in
            check
              (list string)
              "paths"
              [ "/project/skills/utils.py"; "/project/skills/lib/helper.py" ]
              paths)
        ; test_case "no path returns raw" `Quick (fun () ->
            let md = "---\nsupporting-files: a.py\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (list string) "paths" [ "a.py" ] (Skill.supporting_file_paths skill))
        ; test_case "absolute paths preserved" `Quick (fun () ->
            let md = "---\nsupporting-files: /abs/path.py\n---\nbody" in
            let skill = Skill.of_markdown ~path:"/project/skills/test.md" md in
            let paths = Skill.supporting_file_paths skill in
            check (list string) "abs" [ "/abs/path.py" ] paths)
        ] )
    ; ( "string_helpers"
      , [ test_case "strip_quotes double" `Quick (fun () ->
            check string "stripped" "hello" (Skill.strip_quotes "\"hello\""))
        ; test_case "strip_quotes single" `Quick (fun () ->
            check string "stripped" "world" (Skill.strip_quotes "'world'"))
        ; test_case "strip_quotes none" `Quick (fun () ->
            check string "unchanged" "no quotes" (Skill.strip_quotes "no quotes"))
        ; test_case "strip_quotes empty" `Quick (fun () ->
            check string "empty" "" (Skill.strip_quotes ""))
        ; test_case "strip_quotes short" `Quick (fun () ->
            check string "short" "x" (Skill.strip_quotes "x"))
        ; test_case "strip_quotes spaces" `Quick (fun () ->
            check string "trimmed" "hello" (Skill.strip_quotes "  hello  "))
        ; test_case "split_csv basic" `Quick (fun () ->
            check (list string) "csv" [ "a"; "b"; "c" ] (Skill.split_csv "a, b, c"))
        ; test_case "split_csv brackets" `Quick (fun () ->
            check (list string) "csv" [ "x"; "y" ] (Skill.split_csv "[x, y]"))
        ; test_case "split_csv quoted" `Quick (fun () ->
            check (list string) "csv" [ "a"; "b" ] (Skill.split_csv "\"a\", 'b'"))
        ; test_case "split_csv empty" `Quick (fun () ->
            check (list string) "csv" [] (Skill.split_csv ""))
        ; test_case "replace_all basic" `Quick (fun () ->
            check
              string
              "replaced"
              "hi world"
              (Skill.replace_all ~pattern:"hello" ~replacement:"hi" "hello world"))
        ; test_case "replace_all multiple" `Quick (fun () ->
            check
              string
              "replaced"
              "x and x"
              (Skill.replace_all ~pattern:"y" ~replacement:"x" "y and y"))
        ; test_case "replace_all empty_pattern" `Quick (fun () ->
            check
              string
              "unchanged"
              "text"
              (Skill.replace_all ~pattern:"" ~replacement:"x" "text"))
        ; test_case "replace_all no_match" `Quick (fun () ->
            check
              string
              "unchanged"
              "hello"
              (Skill.replace_all ~pattern:"xyz" ~replacement:"abc" "hello"))
        ; test_case "replace_all short_text" `Quick (fun () ->
            check
              string
              "short"
              "ab"
              (Skill.replace_all ~pattern:"xyz" ~replacement:"abc" "ab"))
        ] )
    ; ( "frontmatter_edge"
      , [ test_case "blank lines before ---" `Quick (fun () ->
            let md = "\n\n---\nname: test\n---\nbody" in
            let skill = Skill.of_markdown md in
            check string "name" "test" skill.name)
        ; test_case "CR/LF line endings" `Quick (fun () ->
            let md = "---\r\nname: crlf\r\n---\r\nbody text" in
            let skill = Skill.of_markdown md in
            check string "name" "crlf" skill.name)
        ; test_case "comment lines ignored" `Quick (fun () ->
            let md =
              "---\nname: test\n# This is a comment\ndescription: desc\n---\nbody"
            in
            let skill = Skill.of_markdown md in
            check string "name" "test" skill.name;
            check (option string) "desc" (Some "desc") skill.description)
        ; test_case "empty value" `Quick (fun () ->
            let md = "---\nname:\n---\nbody" in
            let skill = Skill.of_markdown md in
            (* Empty name falls through to default *)
            check string "body" "body" skill.body)
        ; test_case "model field" `Quick (fun () ->
            let md = "---\nmodel: gpt-4\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (option string) "model" (Some "gpt-4") skill.model)
        ; test_case "argument_hint with dash" `Quick (fun () ->
            let md = "---\nargument-hint: <PR number>\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (option string) "hint" (Some "<PR number>") skill.argument_hint)
        ; test_case "argument_hint with underscore" `Quick (fun () ->
            let md = "---\nargument_hint: <branch>\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (option string) "hint" (Some "<branch>") skill.argument_hint)
        ; test_case "no closing ---" `Quick (fun () ->
            let md = "---\nname: unclosed\nno end marker" in
            let skill = Skill.of_markdown md in
            check string "name" "unclosed" skill.name;
            check string "body" "" skill.body)
        ; test_case "list items with quotes" `Quick (fun () ->
            let md = "---\nallowed-tools:\n- \"Read\"\n- 'Write'\n---\nbody" in
            let skill = Skill.of_markdown md in
            check (list string) "tools" [ "Read"; "Write" ] skill.allowed_tools)
        ; test_case "list item without key" `Quick (fun () ->
            (* - item before any key should be ignored *)
            let md = "---\n- orphan\nname: test\n---\nbody" in
            let skill = Skill.of_markdown md in
            check string "name" "test" skill.name)
        ; test_case "no colon line" `Quick (fun () ->
            let md = "---\nname: test\njust text no colon\n---\nbody" in
            let skill = Skill.of_markdown md in
            check string "name" "test" skill.name)
        ] )
    ; ( "scope"
      , [ test_case "scope_of_string project" `Quick (fun () ->
            check bool "project" true (Skill.scope_of_string "project" = Skill.Project))
        ; test_case "scope_of_string user" `Quick (fun () ->
            check bool "user" true (Skill.scope_of_string "user" = Skill.User))
        ; test_case "scope_of_string local" `Quick (fun () ->
            check bool "local" true (Skill.scope_of_string "local" = Skill.Local))
        ; test_case "scope_of_string custom" `Quick (fun () ->
            check bool "custom" true (Skill.scope_of_string "team" = Skill.Custom "team"))
        ] )
    ; ( "load"
      , [ test_case "load missing file" `Quick (fun () ->
            match Skill.load "/nonexistent/file.md" with
            | Error _ -> ()
            | Ok _ -> fail "expected error for missing file")
        ] )
    ; ( "show"
      , [ test_case "show_scope" `Quick (fun () ->
            check
              bool
              "non-empty"
              true
              (String.length (Skill.show_scope Skill.Project) > 0))
        ; test_case "show_t" `Quick (fun () ->
            let skill = Skill.of_markdown "body" in
            check bool "non-empty" true (String.length (Skill.show skill) > 0))
        ] )
    ]
;;
