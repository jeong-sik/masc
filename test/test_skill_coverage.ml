(** Extended Skill coverage tests — targets uncovered paths in skill.ml.

    Focuses on:
    - strip_quotes edge cases
    - split_csv with brackets, whitespace
    - replace_all edge cases
    - parse_frontmatter with various formats
    - frontmatter_value / frontmatter_values
    - scope_of_string
    - of_markdown with full frontmatter
    - render_prompt with $ARGUMENTS and {{arguments}}
    - supporting_file_paths with absolute and relative paths
    - load error handling (non-existent file) *)

open Agent_sdk

(* ── strip_quotes ─────────────────────────────────────────── *)

let test_strip_quotes_double () =
  Alcotest.(check string) "double" "hello" (Skill.strip_quotes {|"hello"|})
;;

let test_strip_quotes_single () =
  Alcotest.(check string) "single" "world" (Skill.strip_quotes "'world'")
;;

let test_strip_quotes_none () =
  Alcotest.(check string) "no quotes" "plain" (Skill.strip_quotes "plain")
;;

let test_strip_quotes_mismatched () =
  Alcotest.(check string) "mismatched" {|"hello'|} (Skill.strip_quotes {|"hello'|})
;;

let test_strip_quotes_empty () =
  Alcotest.(check string) "empty" "" (Skill.strip_quotes "")
;;

let test_strip_quotes_single_char () =
  Alcotest.(check string) "single char" "x" (Skill.strip_quotes "x")
;;

let test_strip_quotes_whitespace () =
  Alcotest.(check string) "trimmed" "hello" (Skill.strip_quotes "  hello  ")
;;

(* ── split_csv ────────────────────────────────────────────── *)

let test_split_csv_simple () =
  let result = Skill.split_csv "a, b, c" in
  Alcotest.(check (list string)) "three items" [ "a"; "b"; "c" ] result
;;

let test_split_csv_brackets () =
  let result = Skill.split_csv "[tool1, tool2]" in
  Alcotest.(check (list string)) "bracket removal" [ "tool1"; "tool2" ] result
;;

let test_split_csv_quoted () =
  let result = Skill.split_csv {|"a", "b"|} in
  Alcotest.(check (list string)) "quoted" [ "a"; "b" ] result
;;

let test_split_csv_empty () =
  let result = Skill.split_csv "" in
  Alcotest.(check (list string)) "empty" [] result
;;

let test_split_csv_single () =
  let result = Skill.split_csv "only" in
  Alcotest.(check (list string)) "single" [ "only" ] result
;;

(* ── replace_all ──────────────────────────────────────────── *)

let test_replace_all_basic () =
  let result = Skill.replace_all ~pattern:"X" ~replacement:"Y" "aXbXc" in
  Alcotest.(check string) "replaced" "aYbYc" result
;;

let test_replace_all_no_match () =
  let result = Skill.replace_all ~pattern:"Z" ~replacement:"Y" "abc" in
  Alcotest.(check string) "unchanged" "abc" result
;;

let test_replace_all_empty_pattern () =
  let result = Skill.replace_all ~pattern:"" ~replacement:"Y" "abc" in
  Alcotest.(check string) "empty pattern unchanged" "abc" result
;;

let test_replace_all_longer_replacement () =
  let result = Skill.replace_all ~pattern:"X" ~replacement:"YYY" "aXb" in
  Alcotest.(check string) "longer" "aYYYb" result
;;

let test_replace_all_shorter_than_pattern () =
  let result = Skill.replace_all ~pattern:"longpattern" ~replacement:"Y" "ab" in
  Alcotest.(check string) "short text" "ab" result
;;

(* ── parse_frontmatter ────────────────────────────────────── *)

let test_parse_frontmatter_full () =
  let md =
    {|---
name: my-skill
description: A test skill
allowed-tools: [tool1, tool2]
model: claude-3
---
Body content here.|}
  in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check string) "body" "Body content here." body;
  Alcotest.(check (option string))
    "name"
    (Some "my-skill")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check (option string))
    "description"
    (Some "A test skill")
    (Skill.frontmatter_value fm "description");
  Alcotest.(check (option string))
    "model"
    (Some "claude-3")
    (Skill.frontmatter_value fm "model")
;;

let test_parse_frontmatter_no_frontmatter () =
  let md = "Just body text" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (list (pair string (list string)))) "empty fm" [] fm;
  Alcotest.(check string) "body is all" "Just body text" body
;;

let test_parse_frontmatter_empty () =
  let fm, body = Skill.parse_frontmatter "" in
  Alcotest.(check (list (pair string (list string)))) "empty fm" [] fm;
  Alcotest.(check string) "empty body" "" body
;;

let test_parse_frontmatter_list_items () =
  let md =
    {|---
name: test
allowed-tools:
  - tool1
  - tool2
  - tool3
---
Body|}
  in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check string) "body" "Body" body;
  let tools = Skill.frontmatter_values fm "allowed-tools" in
  Alcotest.(check (list string)) "three tools" [ "tool1"; "tool2"; "tool3" ] tools
;;

let test_parse_frontmatter_cr_lf () =
  let md = "---\r\nname: test\r\n---\r\nBody" in
  let fm, body = Skill.parse_frontmatter md in
  Alcotest.(check (option string))
    "name"
    (Some "test")
    (Skill.frontmatter_value fm "name");
  Alcotest.(check string) "body" "Body" body
;;

(* ── frontmatter_value / frontmatter_values ───────────────── *)

let test_frontmatter_value_missing () =
  let fm = [ "name", [ "val" ] ] in
  Alcotest.(check (option string)) "missing" None (Skill.frontmatter_value fm "missing")
;;

let test_frontmatter_value_empty_list () =
  let fm = [ "empty", [] ] in
  Alcotest.(check (option string)) "empty list" None (Skill.frontmatter_value fm "empty")
;;

let test_frontmatter_values_present () =
  let fm = [ "tags", [ "a"; "b"; "c" ] ] in
  let vals = Skill.frontmatter_values fm "tags" in
  Alcotest.(check (list string)) "three values" [ "a"; "b"; "c" ] vals
;;

let test_frontmatter_values_missing () =
  let fm = [] in
  let vals = Skill.frontmatter_values fm "missing" in
  Alcotest.(check (list string)) "empty" [] vals
;;

(* ── scope_of_string ──────────────────────────────────────── *)

let test_scope_of_string () =
  Alcotest.(check bool) "project" true (Skill.scope_of_string "project" = Skill.Project);
  Alcotest.(check bool) "user" true (Skill.scope_of_string "user" = Skill.User);
  Alcotest.(check bool) "local" true (Skill.scope_of_string "local" = Skill.Local);
  Alcotest.(check bool)
    "custom"
    true
    (Skill.scope_of_string "custom_scope" = Skill.Custom "custom_scope")
;;

(* ── of_markdown ──────────────────────────────────────────── *)

let test_of_markdown_full () =
  let md =
    {|---
name: my-skill
description: A skill description
scope: project
allowed-tools: [bash, read]
argument-hint: <file_path>
model: claude-3
supporting-files: [helpers.sh]
---
Do the thing with $ARGUMENTS|}
  in
  let skill = Skill.of_markdown ~path:"/skills/my-skill.md" md in
  Alcotest.(check string) "name" "my-skill" skill.name;
  Alcotest.(check (option string)) "desc" (Some "A skill description") skill.description;
  Alcotest.(check (option string)) "path" (Some "/skills/my-skill.md") skill.path;
  (match skill.scope with
   | Some Skill.Project -> ()
   | _ -> Alcotest.fail "expected Project scope");
  Alcotest.(check (list string)) "tools" [ "bash"; "read" ] skill.allowed_tools;
  Alcotest.(check (option string)) "hint" (Some "<file_path>") skill.argument_hint;
  Alcotest.(check (option string)) "model" (Some "claude-3") skill.model;
  Alcotest.(check (list string)) "supporting" [ "helpers.sh" ] skill.supporting_files
;;

let test_of_markdown_no_frontmatter () =
  let skill = Skill.of_markdown "Just a body" in
  Alcotest.(check string) "name default" "skill" skill.name;
  Alcotest.(check string) "body" "Just a body" skill.body;
  Alcotest.(check bool) "no scope" true (skill.scope = None)
;;

let test_of_markdown_name_from_path () =
  let skill = Skill.of_markdown ~path:"/a/b/my-tool.md" "Body only" in
  Alcotest.(check string) "name from path" "my-tool" skill.name
;;

(* ── render_prompt ────────────────────────────────────────── *)

let test_render_prompt_no_args () =
  let skill = Skill.of_markdown "Do the thing" in
  let result = Skill.render_prompt skill in
  Alcotest.(check string) "no substitution" "Do the thing" result
;;

let test_render_prompt_dollar_args () =
  let skill = Skill.of_markdown "Process $ARGUMENTS now" in
  let result = Skill.render_prompt ~arguments:"file.txt" skill in
  Alcotest.(check string) "dollar sub" "Process file.txt now" result
;;

let test_render_prompt_mustache_args () =
  let skill = Skill.of_markdown "Process {{arguments}} now" in
  let result = Skill.render_prompt ~arguments:"file.txt" skill in
  Alcotest.(check string) "mustache sub" "Process file.txt now" result
;;

let test_render_prompt_both_args () =
  let skill = Skill.of_markdown "$ARGUMENTS and {{arguments}}" in
  let result = Skill.render_prompt ~arguments:"X" skill in
  Alcotest.(check string) "both replaced" "X and X" result
;;

(* ── supporting_file_paths ────────────────────────────────── *)

let test_supporting_no_path () =
  let skill =
    { (Skill.of_markdown "") with path = None; supporting_files = [ "file.sh" ] }
  in
  let paths = Skill.supporting_file_paths skill in
  Alcotest.(check (list string)) "raw files" [ "file.sh" ] paths
;;

let test_supporting_with_path () =
  let skill =
    { (Skill.of_markdown "") with
      path = Some "/skills/sub/skill.md"
    ; supporting_files = [ "helpers.sh"; "/abs/path.sh" ]
    }
  in
  let paths = Skill.supporting_file_paths skill in
  Alcotest.(check int) "two paths" 2 (List.length paths);
  Alcotest.(check string) "relative resolved" "/skills/sub/helpers.sh" (List.hd paths);
  Alcotest.(check string) "absolute kept" "/abs/path.sh" (List.nth paths 1)
;;

(* ── load error ───────────────────────────────────────────── *)

let test_load_nonexistent () =
  match Skill.load "/nonexistent/path/skill.md" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for non-existent file"
;;

(* ── show functions ───────────────────────────────────────── *)

let test_scope_show () =
  let scopes = [ Skill.Project; Skill.User; Skill.Local; Skill.Custom "x" ] in
  List.iter
    (fun s ->
       let str = Skill.show_scope s in
       Alcotest.(check bool) "non-empty" true (String.length str > 0))
    scopes
;;

let test_skill_show () =
  let skill = Skill.of_markdown "test" in
  let s = Skill.show skill in
  Alcotest.(check bool) "non-empty" true (String.length s > 0)
;;

(* ── Suite ────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "Skill_coverage"
    [ ( "strip_quotes"
      , [ Alcotest.test_case "double" `Quick test_strip_quotes_double
        ; Alcotest.test_case "single" `Quick test_strip_quotes_single
        ; Alcotest.test_case "none" `Quick test_strip_quotes_none
        ; Alcotest.test_case "mismatched" `Quick test_strip_quotes_mismatched
        ; Alcotest.test_case "empty" `Quick test_strip_quotes_empty
        ; Alcotest.test_case "single char" `Quick test_strip_quotes_single_char
        ; Alcotest.test_case "whitespace" `Quick test_strip_quotes_whitespace
        ] )
    ; ( "split_csv"
      , [ Alcotest.test_case "simple" `Quick test_split_csv_simple
        ; Alcotest.test_case "brackets" `Quick test_split_csv_brackets
        ; Alcotest.test_case "quoted" `Quick test_split_csv_quoted
        ; Alcotest.test_case "empty" `Quick test_split_csv_empty
        ; Alcotest.test_case "single" `Quick test_split_csv_single
        ] )
    ; ( "replace_all"
      , [ Alcotest.test_case "basic" `Quick test_replace_all_basic
        ; Alcotest.test_case "no match" `Quick test_replace_all_no_match
        ; Alcotest.test_case "empty pattern" `Quick test_replace_all_empty_pattern
        ; Alcotest.test_case
            "longer replacement"
            `Quick
            test_replace_all_longer_replacement
        ; Alcotest.test_case
            "shorter than pattern"
            `Quick
            test_replace_all_shorter_than_pattern
        ] )
    ; ( "frontmatter"
      , [ Alcotest.test_case "full" `Quick test_parse_frontmatter_full
        ; Alcotest.test_case "no frontmatter" `Quick test_parse_frontmatter_no_frontmatter
        ; Alcotest.test_case "empty" `Quick test_parse_frontmatter_empty
        ; Alcotest.test_case "list items" `Quick test_parse_frontmatter_list_items
        ; Alcotest.test_case "cr lf" `Quick test_parse_frontmatter_cr_lf
        ] )
    ; ( "frontmatter_values"
      , [ Alcotest.test_case "value missing" `Quick test_frontmatter_value_missing
        ; Alcotest.test_case "value empty list" `Quick test_frontmatter_value_empty_list
        ; Alcotest.test_case "values present" `Quick test_frontmatter_values_present
        ; Alcotest.test_case "values missing" `Quick test_frontmatter_values_missing
        ] )
    ; ( "scope"
      , [ Alcotest.test_case "of_string" `Quick test_scope_of_string
        ; Alcotest.test_case "show" `Quick test_scope_show
        ] )
    ; ( "of_markdown"
      , [ Alcotest.test_case "full" `Quick test_of_markdown_full
        ; Alcotest.test_case "no frontmatter" `Quick test_of_markdown_no_frontmatter
        ; Alcotest.test_case "name from path" `Quick test_of_markdown_name_from_path
        ] )
    ; ( "render_prompt"
      , [ Alcotest.test_case "no args" `Quick test_render_prompt_no_args
        ; Alcotest.test_case "dollar args" `Quick test_render_prompt_dollar_args
        ; Alcotest.test_case "mustache args" `Quick test_render_prompt_mustache_args
        ; Alcotest.test_case "both args" `Quick test_render_prompt_both_args
        ] )
    ; ( "supporting"
      , [ Alcotest.test_case "no path" `Quick test_supporting_no_path
        ; Alcotest.test_case "with path" `Quick test_supporting_with_path
        ] )
    ; "load", [ Alcotest.test_case "nonexistent" `Quick test_load_nonexistent ]
    ; "show", [ Alcotest.test_case "skill show" `Quick test_skill_show ]
    ]
;;
