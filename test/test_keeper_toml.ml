open Alcotest

module TL = Masc_mcp.Keeper_toml_loader
module KTP = Masc_mcp.Keeper_types_profile

(* ================================================================ *)
(* TOML parser tests                                                 *)
(* ================================================================ *)

let test_parse_empty () =
  match TL.parse_toml "" with
  | Ok doc -> check int "empty doc" 0 (List.length doc)
  | Error e -> fail e

let test_parse_comments_and_blanks () =
  let input = {|
# This is a comment
   # indented comment

  |} in
  match TL.parse_toml input with
  | Ok doc -> check int "no entries" 0 (List.length doc)
  | Error e -> fail e

let test_parse_string_value () =
  let input = {|key = "hello world"|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "string value" "hello world" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_string_escapes () =
  let input = {|key = "line1\nline2\ttab"|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "escapes" "line1\nline2\ttab" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_int_value () =
  let input = "count = 42" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "count" doc with
     | Some (TL.Toml_int i) -> check int "int value" 42 i
     | _ -> fail "expected Toml_int")
  | Error e -> fail e

let test_parse_negative_int () =
  let input = "offset = -10" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "offset" doc with
     | Some (TL.Toml_int i) -> check int "negative int" (-10) i
     | _ -> fail "expected Toml_int")
  | Error e -> fail e

let test_parse_float_value () =
  let input = "ratio = 0.75" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "ratio" doc with
     | Some (TL.Toml_float f) ->
       check (float 0.001) "float value" 0.75 f
     | _ -> fail "expected Toml_float")
  | Error e -> fail e

let test_parse_bool_values () =
  let input = "enabled = true\ndisabled = false" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "enabled" doc with
     | Some (TL.Toml_bool b) -> check bool "true" true b
     | _ -> fail "expected true");
    (match List.assoc_opt "disabled" doc with
     | Some (TL.Toml_bool b) -> check bool "false" false b
     | _ -> fail "expected false")
  | Error e -> fail e

let test_parse_string_array () =
  let input = {|tags = ["alpha", "beta", "gamma"]|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "tags" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "array length" 3 (List.length xs);
       check string "first" "alpha" (List.nth xs 0);
       check string "second" "beta" (List.nth xs 1);
       check string "third" "gamma" (List.nth xs 2)
     | _ -> fail "expected Toml_string_array")
  | Error e -> fail e

let test_parse_empty_array () =
  let input = "items = []" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "items" doc with
     | Some (TL.Toml_string_array xs) ->
       check int "empty array" 0 (List.length xs)
     | _ -> fail "expected empty Toml_string_array")
  | Error e -> fail e

let test_parse_table () =
  let input = {|
[keeper]
goal = "test goal"
count = 5
|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "keeper.goal" doc with
     | Some (TL.Toml_string s) -> check string "table key" "test goal" s
     | _ -> fail "expected keeper.goal");
    (match List.assoc_opt "keeper.count" doc with
     | Some (TL.Toml_int i) -> check int "table int" 5 i
     | _ -> fail "expected keeper.count")
  | Error e -> fail e

let test_parse_inline_comment () =
  let input = {|key = "value" # this is a comment|} in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "value with comment" "value" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_multiline_string () =
  let input = "[keeper]\ngoal = \"test\"\ninstructions = \"\"\"\nLine one.\nLine two.\n\"\"\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "keeper.instructions" doc with
     | Some (TL.Toml_string s) ->
       check string "multiline content" "Line one.\nLine two." s
     | _ -> fail "expected Toml_string for multiline")
  | Error e -> fail e

let test_parse_multiline_string_single_line_form () =
  let input = {|key = """short"""|}  in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "key" doc with
     | Some (TL.Toml_string s) -> check string "single-line triple" "short" s
     | _ -> fail "expected Toml_string")
  | Error e -> fail e

let test_parse_multiline_string_unterminated () =
  let input = "key = \"\"\"\nno closing" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected error for unterminated multiline"
  | Error _ -> ()

let test_parse_multiline_with_keys_after () =
  let input = "[keeper]\ninstructions = \"\"\"\nDo stuff.\n\"\"\"\nroom_scope = \"all\"" in
  match TL.parse_toml input with
  | Ok doc ->
    (match List.assoc_opt "keeper.instructions" doc with
     | Some (TL.Toml_string s) -> check string "ml content" "Do stuff." s
     | _ -> fail "expected instructions");
    (match List.assoc_opt "keeper.room_scope" doc with
     | Some (TL.Toml_string s) -> check string "key after ml" "all" s
     | _ -> fail "expected room_scope after multiline")
  | Error e -> fail e

let test_parse_error_unterminated_table () =
  let input = "[missing_bracket" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

let test_parse_error_no_equals () =
  let input = "no_equals_here" in
  match TL.parse_toml input with
  | Ok _ -> fail "expected parse error"
  | Error _ -> ()

(* ================================================================ *)
(* Profile defaults conversion tests                                 *)
(* ================================================================ *)

let test_profile_minimal () =
  let input = {|
[keeper]
goal = "test goal"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok defaults ->
      check (option string) "goal" (Some "test goal") defaults.goal;
      check (option string) "soul_profile" None defaults.soul_profile

let test_profile_full () =
  let input = {|
[keeper]
goal = "analyze logs"
short_goal = "current session"
mid_goal = "build patterns"
long_goal = "continuous improvement"
soul_profile = "research"
will = "detect issues"
needs = "log access"
desires = "low false positives"
instructions = "You are a log analyzer."
room_scope = "all"
scope_kind = "global"
mention_targets = ["sherlock", "log-analyzer"]
proactive_enabled = true
room_signal_prompt_enabled = true
policy_voice_enabled = false
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Error e -> fail e
    | Ok d ->
      check (option string) "goal" (Some "analyze logs") d.goal;
      check (option string) "soul_profile" (Some "research") d.soul_profile;
      check (option string) "will" (Some "detect issues") d.will;
      check (option string) "room_scope" (Some "all") d.room_scope;
      check int "mention_targets" 2 (List.length d.mention_targets);
      check (option bool) "proactive" (Some true) d.proactive_enabled;
      check (option bool) "room signal prompt" (Some true)
        d.room_signal_prompt_enabled;
      check (option bool) "policy_voice" (Some false) d.policy_voice_enabled

let test_profile_invalid_soul_profile () =
  let input = {|
[keeper]
goal = "test"
soul_profile = "nonexistent"
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
    match KTP.profile_defaults_of_toml doc with
    | Ok _ -> fail "expected validation error for invalid soul_profile"
    | Error msg ->
      check bool "mentions invalid or soul" true
        (let lc = String.lowercase_ascii msg in
         try ignore (Str.search_forward (Str.regexp "invalid\\|soul\\|unknown") lc 0); true
         with Not_found -> false)

let test_profile_rejects_removed_model_keys () =
  let input = {|
[keeper]
goal = "test"
models = ["llama:test"]
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected removed TOML key error"
       | Error msg ->
           check bool "mentions removed models key" true
             (try
                ignore
                  (Str.search_forward
                     (Str.regexp_string "keeper.models")
                     msg 0);
                true
              with Not_found -> false))

let test_profile_rejects_removed_initiative_keys () =
  let input = {|
[keeper]
goal = "test"
initiative_enabled = true
|} in
  match TL.parse_toml input with
  | Error e -> fail e
  | Ok doc ->
      (match KTP.profile_defaults_of_toml doc with
       | Ok _ -> fail "expected removed TOML key error"
       | Error msg ->
           check bool "mentions removed initiative key" true
             (try
                ignore
                  (Str.search_forward
                     (Str.regexp_string "keeper.initiative_enabled")
                     msg 0);
                true
              with Not_found -> false))

(* ================================================================ *)
(* File loading tests                                                *)
(* ================================================================ *)

let test_load_from_file () =
  (* Write a temp file *)
  let tmp = Filename.temp_file "keeper_toml_test" ".toml" in
  let content = {|
[keeper]
name = "test-keeper"
goal = "testing file load"
soul_profile = "balanced"
|} in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml tmp with
   | Error e -> fail e
   | Ok (name, defaults) ->
     check string "name from toml" "test-keeper" name;
     check (option string) "goal" (Some "testing file load") defaults.goal;
     check (option string) "manifest" (Some tmp) defaults.manifest_path);
  Sys.remove tmp

let test_load_name_from_filename () =
  let tmp_dir = Filename.get_temp_dir_name () in
  let path = Filename.concat tmp_dir "my-analyzer.toml" in
  let content = {|
[keeper]
goal = "analyze stuff"
|} in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml path with
   | Error e -> fail e
   | Ok (name, _) ->
     check string "name from filename" "my-analyzer" name);
  Sys.remove path

let test_load_invalid_name () =
  let tmp = Filename.temp_file "keeper_toml_test" ".toml" in
  let content = {|
[keeper]
name = "invalid name with spaces"
goal = "test"
|} in
  let oc = open_out tmp in
  output_string oc content;
  close_out oc;
  (match KTP.load_keeper_toml tmp with
   | Ok _ -> fail "expected error for invalid name"
   | Error _ -> ());
  Sys.remove tmp

(* ================================================================ *)
(* Discovery tests                                                   *)
(* ================================================================ *)

let test_discover_empty_dir () =
  let tmp_dir = Filename.temp_file "keeper_discover" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "empty dir" 0 (List.length result);
  Unix.rmdir tmp_dir

let test_discover_with_files () =
  let tmp_dir = Filename.temp_file "keeper_discover" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  (* Create two TOML files *)
  let write_file name content =
    let path = Filename.concat tmp_dir name in
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  write_file "alpha.toml" {|
[keeper]
goal = "alpha goal"
|};
  write_file "beta.toml" {|
[keeper]
goal = "beta goal"
|};
  write_file "not-toml.json" {|{"ignored": true}|};
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "two keepers" 2 (List.length result);
  let names = List.map fst result in
  check bool "has alpha" true (List.mem "alpha" names);
  check bool "has beta" true (List.mem "beta" names);
  (* Cleanup *)
  Array.iter
    (fun f -> Sys.remove (Filename.concat tmp_dir f))
    (Sys.readdir tmp_dir);
  Unix.rmdir tmp_dir

let test_discover_nonexistent_dir () =
  let result = KTP.discover_keepers_toml "/nonexistent/path/keepers" in
  check int "nonexistent dir" 0 (List.length result)

let test_discover_skips_bad_files () =
  let tmp_dir = Filename.temp_file "keeper_discover" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  let write_file name content =
    let path = Filename.concat tmp_dir name in
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  write_file "good.toml" {|
[keeper]
goal = "works"
|};
  write_file "bad.toml" "[broken";
  let result = KTP.discover_keepers_toml tmp_dir in
  check int "one good keeper" 1 (List.length result);
  check string "good name" "good" (fst (List.hd result));
  Array.iter
    (fun f -> Sys.remove (Filename.concat tmp_dir f))
    (Sys.readdir tmp_dir);
  Unix.rmdir tmp_dir

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" then ()
  else if Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755
  end

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let with_personas_dir f =
  with_temp_dir "keeper-personas" @@ fun personas_dir ->
  let original = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
      | Some value -> Unix.putenv "MASC_PERSONAS_DIR" value
      | None -> Unix.putenv "MASC_PERSONAS_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_PERSONAS_DIR" personas_dir;
      Masc_mcp.Config_dir_resolver.reset ();
      f personas_dir)

let test_persona_profile_canonicalizes_soul_profile () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test",
    "soul_profile": "delivery"
  }
}
|};
  let defaults = KTP.load_keeper_profile_defaults_from_persona "probe" in
  check (option string) "canonical soul_profile" (Some "delivery") defaults.soul_profile

let test_persona_profile_ignores_invalid_soul_profile () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test",
    "soul_profile": "utility"
  }
}
|};
  let defaults = KTP.load_keeper_profile_defaults_from_persona "probe" in
  check (option string) "invalid soul_profile dropped" None defaults.soul_profile

let test_persona_resolver_defaults_to_research_tool_preset () =
  with_personas_dir @@ fun personas_dir ->
  let persona_dir = Filename.concat personas_dir "probe" in
  mkdir_p persona_dir;
  write_file
    (Filename.concat persona_dir "profile.json")
    {|
{
  "name": "Probe",
  "keeper": {
    "goal": "test persona keeper"
  }
}
|};
  match
    Masc_mcp.Keeper_exec_persona.resolved_keeper_args_from_persona
      (`Assoc [ ("persona_name", `String "probe") ])
  with
  | Error e -> fail ("resolver failed: " ^ e)
  | Ok (_, resolved) ->
      let tool_preset = Yojson.Safe.Util.member "tool_preset" resolved in
      check string "persona default tool_preset" "research"
        (Yojson.Safe.Util.to_string tool_preset)

(* ================================================================ *)
(* Test suite                                                        *)
(* ================================================================ *)

let () =
  run "Keeper TOML Loader"
    [
      ( "parser",
        [
          test_case "empty" `Quick test_parse_empty;
          test_case "comments and blanks" `Quick test_parse_comments_and_blanks;
          test_case "string value" `Quick test_parse_string_value;
          test_case "string escapes" `Quick test_parse_string_escapes;
          test_case "int value" `Quick test_parse_int_value;
          test_case "negative int" `Quick test_parse_negative_int;
          test_case "float value" `Quick test_parse_float_value;
          test_case "bool values" `Quick test_parse_bool_values;
          test_case "string array" `Quick test_parse_string_array;
          test_case "empty array" `Quick test_parse_empty_array;
          test_case "table" `Quick test_parse_table;
          test_case "inline comment" `Quick test_parse_inline_comment;
          test_case "multiline string" `Quick test_parse_multiline_string;
          test_case "multiline single-line form" `Quick test_parse_multiline_string_single_line_form;
          test_case "multiline unterminated" `Quick test_parse_multiline_string_unterminated;
          test_case "multiline with keys after" `Quick test_parse_multiline_with_keys_after;
          test_case "error: unterminated table" `Quick test_parse_error_unterminated_table;
          test_case "error: no equals" `Quick test_parse_error_no_equals;
        ] );
      ( "profile_defaults",
        [
          test_case "minimal" `Quick test_profile_minimal;
          test_case "full" `Quick test_profile_full;
          test_case "invalid soul_profile" `Quick test_profile_invalid_soul_profile;
          test_case "rejects removed model keys" `Quick
            test_profile_rejects_removed_model_keys;
          test_case "rejects removed initiative keys" `Quick
            test_profile_rejects_removed_initiative_keys;
        ] );
      ( "file_loading",
        [
          test_case "load from file" `Quick test_load_from_file;
          test_case "name from filename" `Quick test_load_name_from_filename;
          test_case "invalid name" `Quick test_load_invalid_name;
        ] );
      ( "discovery",
        [
          test_case "empty dir" `Quick test_discover_empty_dir;
          test_case "with files" `Quick test_discover_with_files;
          test_case "nonexistent dir" `Quick test_discover_nonexistent_dir;
          test_case "skips bad files" `Quick test_discover_skips_bad_files;
          test_case "persona profile canonicalizes soul_profile" `Quick
            test_persona_profile_canonicalizes_soul_profile;
          test_case "persona profile ignores invalid soul_profile" `Quick
            test_persona_profile_ignores_invalid_soul_profile;
          test_case "persona resolver defaults to research tool_preset" `Quick
            test_persona_resolver_defaults_to_research_tool_preset;
        ] );
    ]
