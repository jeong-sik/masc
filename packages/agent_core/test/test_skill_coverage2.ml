(** Extended Skill and Skill_registry coverage — targeting remaining uncovered paths.

    Existing tests cover:
    - strip_quotes, split_csv, replace_all, parse_frontmatter basics
    - frontmatter_value/values, scope_of_string
    - of_markdown (full/no_frontmatter/name_from_path)
    - render_prompt (no_args/$ARGUMENTS/mustache/both)
    - supporting_file_paths (no_path/with_path)
    - load nonexistent, show functions
    - Skill_registry CRUD, JSON roundtrip, load_from_dir missing

    This file targets uncovered paths in:
    - Skill.ml: parse_frontmatter with blank lines before/inside,
      assoc_replace duplicate keys, of_markdown with scope from arg,
      of_markdown with allowed_tools via allowed-tools AND allowed_tools keys,
      of_markdown with argument_hint via underscore key,
      of_markdown with supporting_files via underscore key,
      replace_all at boundary positions, load_dir (real directory),
      load_dir ignoring dotfiles and non-.md files
    - Skill_registry.ml: skill_to_json with scope, load_from_dir success,
      skill_of_json with allowed_tools as non-list,
      of_json error paths *)

open Agent_sdk

(* ── Skill: parse_frontmatter edge cases ──────────────── *)

let test_parse_frontmatter_leading_blank_lines () =
  let md = "\n\n---\nname: test\n---\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check string) "body" "Body" body
;;

let test_parse_frontmatter_blank_inside () =
  let md = "---\nname: test\n\ndescription: desc\n---\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check (option string))
    "desc"
    (Some "desc")
    (Skill.frontmatter_value fm "description");
  Alcotest.(check string) "body" "Body" body
;;

let test_parse_frontmatter_comment_line () =
  let md = "---\nname: test\n# this is a comment\ndescription: desc\n---\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check (option string))
    "desc"
    (Some "desc")
    (Skill.frontmatter_value fm "description");
  Alcotest.(check string) "body" "Body" body
;;

let test_parse_frontmatter_no_closing () =
  let md = "---\nname: test\nno closing delimiter" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check string) "body empty" "" body
;;

let test_parse_frontmatter_no_colon () =
  let md = "---\nname: test\nweird line without colon\ndescription: d\n---\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check string) "body" "Body" body
;;

let test_parse_frontmatter_duplicate_key () =
  let md = "---\nname: first\nname: second\n---\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name replaced"
    (Some "second")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check string) "body" "Body" body
;;

let test_parse_frontmatter_list_item_no_current_key () =
  let md = "---\n- orphan_item\nname: test\n---\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check string) "body" "Body" body
;;

let test_parse_frontmatter_key_empty_then_list () =
  let md = "---\ntools:\n- bash\n- read\n---\nBody" in
  let fm, _body = Skill.parse_frontmatter md in
  let tools = Skill.frontmatter_values fm "tools" in
  Alcotest.(check (list string)) "tools" [ "bash"; "read" ] tools
;;

(* ── Skill: of_markdown with scope from arg ───────────── *)

let test_of_markdown_scope_from_arg () =
  let skill = Skill.of_markdown ~scope:User "Body" in
  match skill.scope with
  | Some Skill.User -> ()
  | _ -> Alcotest.fail "expected User scope from arg"
;;

let test_of_markdown_scope_from_frontmatter_overrides_arg () =
  let md = "---\nscope: local\n---\nBody" in
  let skill = Skill.of_markdown ~scope:Project md in
  match skill.scope with
  | Some Skill.Local -> ()
  | _ -> Alcotest.fail "frontmatter scope should override arg"
;;

(* ── Skill: of_markdown allowed_tools via underscore key ── *)

let test_of_markdown_allowed_tools_underscore () =
  let md = "---\nname: test\nallowed_tools: [bash, read]\n---\nBody" in
  let skill = Skill.of_markdown md in
  Alcotest.(check (list string)) "tools underscore" [ "bash"; "read" ] skill.allowed_tools
;;

let test_of_markdown_allowed_tools_both_keys () =
  let md = "---\nname: test\nallowed-tools: [bash]\nallowed_tools: [read]\n---\nBody" in
  let skill = Skill.of_markdown md in
  (* Both keys are concatenated *)
  Alcotest.(check int) "2 tools" 2 (List.length skill.allowed_tools)
;;

(* ── Skill: of_markdown argument_hint underscore ──────── *)

let test_of_markdown_argument_hint_underscore () =
  let md = "---\nname: test\nargument_hint: <file>\n---\nBody" in
  let skill = Skill.of_markdown md in
  Alcotest.(check (option string)) "hint" (Some "<file>") skill.argument_hint
;;

let test_of_markdown_argument_hint_dash_overrides () =
  let md =
    "---\n\
     name: test\n\
     argument-hint: <from-dash>\n\
     argument_hint: <from-underscore>\n\
     ---\n\
     Body"
  in
  let skill = Skill.of_markdown md in
  (* Dash key has priority *)
  Alcotest.(check (option string))
    "hint from dash"
    (Some "<from-dash>")
    skill.argument_hint
;;

(* ── Skill: of_markdown supporting_files underscore ───── *)

let test_of_markdown_supporting_files_underscore () =
  let md = "---\nname: test\nsupporting_files: [helpers.sh]\n---\nBody" in
  let skill = Skill.of_markdown md in
  Alcotest.(check (list string)) "files" [ "helpers.sh" ] skill.supporting_files
;;

let test_of_markdown_supporting_files_both () =
  let md =
    "---\nname: test\nsupporting-files: [a.sh]\nsupporting_files: [b.sh]\n---\nBody"
  in
  let skill = Skill.of_markdown md in
  Alcotest.(check int) "2 files" 2 (List.length skill.supporting_files)
;;

(* ── Skill: replace_all boundary positions ────────────── *)

let test_replace_all_at_start () =
  let result = Skill.replace_all ~pattern:"ABC" ~replacement:"X" "ABCdef" in
  Alcotest.(check string) "start" "Xdef" result
;;

let test_replace_all_at_end () =
  let result = Skill.replace_all ~pattern:"DEF" ~replacement:"X" "abcDEF" in
  Alcotest.(check string) "end" "abcX" result
;;

let test_replace_all_whole_string () =
  let result = Skill.replace_all ~pattern:"abc" ~replacement:"xyz" "abc" in
  Alcotest.(check string) "whole" "xyz" result
;;

let test_replace_all_overlapping () =
  let result = Skill.replace_all ~pattern:"aa" ~replacement:"b" "aaa" in
  (* First match at 0: "aa" -> "b", then remaining "a" *)
  Alcotest.(check string) "overlapping" "ba" result
;;

let test_replace_all_empty_text () =
  let result = Skill.replace_all ~pattern:"x" ~replacement:"y" "" in
  Alcotest.(check string) "empty text" "" result
;;

(* ── Skill: load_dir ──────────────────────────────────── *)

let test_load_dir_real () =
  let dir = Filename.temp_file "oas_skill_" "_dir" in
  (* Remove the file and create a directory *)
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "test.md") with
       | _ -> ());
      (try Sys.remove (Filename.concat dir ".hidden.md") with
       | _ -> ());
      (try Sys.remove (Filename.concat dir "readme.txt") with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       (* Create test files *)
       let write_file path content =
         let oc = open_out path in
         output_string oc content;
         close_out oc
       in
       write_file (Filename.concat dir "test.md") "---\nname: test-skill\n---\nBody";
       write_file (Filename.concat dir ".hidden.md") "---\nname: hidden\n---\nHidden";
       write_file (Filename.concat dir "readme.txt") "Not a markdown file";
       let skills = Skill.load_dir dir in
       Alcotest.(check int) "1 visible .md file" 1 (List.length skills);
       let s = List.hd skills in
       Alcotest.(check string) "name" "test-skill" s.name)
;;

(* ── Skill: load success ──────────────────────────────── *)

let test_load_success () =
  let path = Filename.temp_file "oas_skill_" ".md" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       let oc = open_out path in
       output_string oc "---\nname: loaded\ndescription: from file\n---\nBody content";
       close_out oc;
       match Skill.load path with
       | Ok skill ->
         Alcotest.(check string) "name" "loaded" skill.name;
         Alcotest.(check (option string)) "desc" (Some "from file") skill.description;
         Alcotest.(check string) "body" "Body content" skill.body;
         Alcotest.(check (option string)) "path" (Some path) skill.path
       | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_load_with_scope () =
  let path = Filename.temp_file "oas_skill_" ".md" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | _ -> ())
    (fun () ->
       let oc = open_out path in
       output_string oc "---\nname: scoped\n---\nBody";
       close_out oc;
       match Skill.load ~scope:Project path with
       | Ok skill ->
         (match skill.scope with
          | Some Skill.Project -> ()
          | _ -> Alcotest.fail "expected Project scope")
       | Error e -> Alcotest.fail (Error.to_string e))
;;

(* ── Skill: render_prompt no arguments (None branch) ──── *)

let test_render_prompt_none_no_sub () =
  let skill = Skill.of_markdown "Process $ARGUMENTS here" in
  let result = Skill.render_prompt skill in
  Alcotest.(check string) "no substitution" "Process $ARGUMENTS here" result
;;

(* ── Skill: supporting_file_paths empty list ──────────── *)

let test_supporting_empty_list () =
  let skill =
    { (Skill.of_markdown "") with path = Some "/skills/s.md"; supporting_files = [] }
  in
  let paths = Skill.supporting_file_paths skill in
  Alcotest.(check (list string)) "empty" [] paths
;;

(* ── Skill_registry: skill_to_json with scope ─────────── *)

let test_skill_to_json_with_scope () =
  let skill =
    { (Skill.of_markdown "---\nname: test\n---\nBody") with scope = Some Project }
  in
  let json = Skill_registry.skill_to_json skill in
  let open Yojson.Safe.Util in
  let scope_str = json |> member "scope" |> to_string in
  Alcotest.(check bool) "scope present" true (String.length scope_str > 0)
;;

let test_skill_to_json_no_scope () =
  let skill = Skill.of_markdown "---\nname: test\n---\nBody" in
  let json = Skill_registry.skill_to_json skill in
  let s = Yojson.Safe.to_string json in
  Alcotest.(check bool) "no scope" false (Util.string_contains ~needle:"\"scope\"" s)
;;

(* ── Skill_registry: load_from_dir success ────────────── *)

let test_load_from_dir_success () =
  let dir = Filename.temp_file "oas_reg_" "_dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "a.md") with
       | _ -> ());
      (try Sys.remove (Filename.concat dir "b.md") with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       let write_file path content =
         let oc = open_out path in
         output_string oc content;
         close_out oc
       in
       write_file (Filename.concat dir "a.md") "---\nname: alpha\n---\nAlpha";
       write_file (Filename.concat dir "b.md") "---\nname: beta\n---\nBeta";
       let reg = Skill_registry.create () in
       match Skill_registry.load_from_dir reg dir with
       | Ok count ->
         Alcotest.(check int) "loaded 2" 2 count;
         Alcotest.(check int) "registry count" 2 (Skill_registry.count reg)
       | Error e -> Alcotest.fail (Error.to_string e))
;;

let test_load_from_dir_with_scope () =
  let dir = Filename.temp_file "oas_reg_" "_dir" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove (Filename.concat dir "s.md") with
       | _ -> ());
      try Unix.rmdir dir with
      | _ -> ())
    (fun () ->
       let oc = open_out (Filename.concat dir "s.md") in
       output_string oc "---\nname: scoped\n---\nBody";
       close_out oc;
       let reg = Skill_registry.create () in
       match Skill_registry.load_from_dir reg ~scope:User dir with
       | Ok 1 -> ()
       | _ -> Alcotest.fail "expected 1 skill loaded")
;;

(* ── Skill_registry: skill_of_json edge cases ─────────── *)

let test_skill_of_json_allowed_tools_non_list () =
  let json =
    `Assoc
      [ "name", `String "t"; "body", `String "b"; "allowed_tools", `String "not-a-list" ]
  in
  match Skill_registry.skill_of_json json with
  | Ok skill -> Alcotest.(check (list string)) "empty tools" [] skill.allowed_tools
  | Error _ -> Alcotest.fail "should parse with non-list tools"
;;

let test_skill_of_json_supporting_files_non_list () =
  let json =
    `Assoc
      [ "name", `String "t"
      ; "body", `String "b"
      ; "supporting_files", `String "not-a-list"
      ]
  in
  match Skill_registry.skill_of_json json with
  | Ok skill -> Alcotest.(check (list string)) "empty files" [] skill.supporting_files
  | Error _ -> Alcotest.fail "should parse with non-list files"
;;

let test_skill_of_json_all_optional_present () =
  let json =
    `Assoc
      [ "name", `String "full"
      ; "body", `String "body"
      ; "description", `String "desc"
      ; "path", `String "/p"
      ; "model", `String "gpt"
      ; "argument_hint", `String "hint"
      ; "allowed_tools", `List [ `String "bash" ]
      ; "supporting_files", `List [ `String "f.sh" ]
      ]
  in
  match Skill_registry.skill_of_json json with
  | Ok skill ->
    Alcotest.(check (option string)) "desc" (Some "desc") skill.description;
    Alcotest.(check (option string)) "path" (Some "/p") skill.path;
    Alcotest.(check (option string)) "model" (Some "gpt") skill.model;
    Alcotest.(check (option string)) "hint" (Some "hint") skill.argument_hint;
    Alcotest.(check (list string)) "tools" [ "bash" ] skill.allowed_tools;
    Alcotest.(check (list string)) "files" [ "f.sh" ] skill.supporting_files
  | Error e -> Alcotest.fail (Error.to_string e)
;;

let test_skill_of_json_mixed_array_items () =
  let json =
    `Assoc
      [ "name", `String "t"
      ; "body", `String "b"
      ; "allowed_tools", `List [ `String "bash"; `Int 42; `String "read" ]
      ]
  in
  match Skill_registry.skill_of_json json with
  | Ok skill ->
    (* Int items are filtered out *)
    Alcotest.(check (list string)) "2 tools" [ "bash"; "read" ] skill.allowed_tools
  | Error _ -> Alcotest.fail "should parse filtering non-strings"
;;

(* ── Skill_registry: of_json additional error ─────────── *)

let test_of_json_no_skills_key () =
  let json = `Assoc [ "count", `Int 0 ] in
  match Skill_registry.of_json json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error without skills key"
;;

(* ── Skill_registry: skill_to_json roundtrip completeness ── *)

let test_skill_to_json_full_fields () =
  let skill : Skill.t =
    { name = "full"
    ; description = Some "desc"
    ; body = "body"
    ; path = Some "/p"
    ; scope = Some (Custom "team")
    ; allowed_tools = [ "bash"; "read" ]
    ; argument_hint = Some "<arg>"
    ; model = Some "gpt-4"
    ; supporting_files = [ "h.sh" ]
    ; metadata = []
    }
  in
  let json = Skill_registry.skill_to_json skill in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "name" "full" (json |> member "name" |> to_string);
  Alcotest.(check string) "desc" "desc" (json |> member "description" |> to_string);
  Alcotest.(check string) "body" "body" (json |> member "body" |> to_string);
  Alcotest.(check string) "path" "/p" (json |> member "path" |> to_string);
  Alcotest.(check string) "model" "gpt-4" (json |> member "model" |> to_string);
  Alcotest.(check string) "hint" "<arg>" (json |> member "argument_hint" |> to_string);
  let tools = json |> member "allowed_tools" |> to_list in
  Alcotest.(check int) "2 tools" 2 (List.length tools);
  let files = json |> member "supporting_files" |> to_list in
  Alcotest.(check int) "1 file" 1 (List.length files)
;;

(* ── Test runner ───────────────────────────────────────── *)

let () =
  Alcotest.run
    "Skill_coverage2"
    [ ( "frontmatter_edge_cases"
      , [ Alcotest.test_case
            "leading blank lines"
            `Quick
            test_parse_frontmatter_leading_blank_lines
        ; Alcotest.test_case "blank inside" `Quick test_parse_frontmatter_blank_inside
        ; Alcotest.test_case "comment line" `Quick test_parse_frontmatter_comment_line
        ; Alcotest.test_case "no closing" `Quick test_parse_frontmatter_no_closing
        ; Alcotest.test_case "no colon" `Quick test_parse_frontmatter_no_colon
        ; Alcotest.test_case "duplicate key" `Quick test_parse_frontmatter_duplicate_key
        ; Alcotest.test_case
            "orphan list item"
            `Quick
            test_parse_frontmatter_list_item_no_current_key
        ; Alcotest.test_case
            "empty key then list"
            `Quick
            test_parse_frontmatter_key_empty_then_list
        ] )
    ; ( "of_markdown_scope"
      , [ Alcotest.test_case "scope from arg" `Quick test_of_markdown_scope_from_arg
        ; Alcotest.test_case
            "frontmatter overrides"
            `Quick
            test_of_markdown_scope_from_frontmatter_overrides_arg
        ] )
    ; ( "of_markdown_tools"
      , [ Alcotest.test_case
            "underscore key"
            `Quick
            test_of_markdown_allowed_tools_underscore
        ; Alcotest.test_case "both keys" `Quick test_of_markdown_allowed_tools_both_keys
        ] )
    ; ( "of_markdown_hint"
      , [ Alcotest.test_case
            "underscore key"
            `Quick
            test_of_markdown_argument_hint_underscore
        ; Alcotest.test_case
            "dash overrides"
            `Quick
            test_of_markdown_argument_hint_dash_overrides
        ] )
    ; ( "of_markdown_files"
      , [ Alcotest.test_case
            "underscore key"
            `Quick
            test_of_markdown_supporting_files_underscore
        ; Alcotest.test_case "both keys" `Quick test_of_markdown_supporting_files_both
        ] )
    ; ( "replace_all_boundary"
      , [ Alcotest.test_case "at start" `Quick test_replace_all_at_start
        ; Alcotest.test_case "at end" `Quick test_replace_all_at_end
        ; Alcotest.test_case "whole string" `Quick test_replace_all_whole_string
        ; Alcotest.test_case "overlapping" `Quick test_replace_all_overlapping
        ; Alcotest.test_case "empty text" `Quick test_replace_all_empty_text
        ] )
    ; ( "load"
      , [ Alcotest.test_case "success" `Quick test_load_success
        ; Alcotest.test_case "with scope" `Quick test_load_with_scope
        ] )
    ; "load_dir", [ Alcotest.test_case "real dir" `Quick test_load_dir_real ]
    ; ( "render_prompt"
      , [ Alcotest.test_case "None no sub" `Quick test_render_prompt_none_no_sub ] )
    ; ( "supporting_paths"
      , [ Alcotest.test_case "empty list" `Quick test_supporting_empty_list ] )
    ; ( "registry_to_json"
      , [ Alcotest.test_case "with scope" `Quick test_skill_to_json_with_scope
        ; Alcotest.test_case "no scope" `Quick test_skill_to_json_no_scope
        ; Alcotest.test_case "full fields" `Quick test_skill_to_json_full_fields
        ] )
    ; ( "registry_load_from_dir"
      , [ Alcotest.test_case "success" `Quick test_load_from_dir_success
        ; Alcotest.test_case "with scope" `Quick test_load_from_dir_with_scope
        ] )
    ; ( "registry_skill_of_json"
      , [ Alcotest.test_case
            "non-list tools"
            `Quick
            test_skill_of_json_allowed_tools_non_list
        ; Alcotest.test_case
            "non-list files"
            `Quick
            test_skill_of_json_supporting_files_non_list
        ; Alcotest.test_case "all optional" `Quick test_skill_of_json_all_optional_present
        ; Alcotest.test_case "mixed array" `Quick test_skill_of_json_mixed_array_items
        ] )
    ; ( "registry_of_json"
      , [ Alcotest.test_case "no skills key" `Quick test_of_json_no_skills_key ] )
    ]
;;
