(** RFC-0027 PR-9a: cascade.json weighted_entry [secondary] field parser.

    Verifies the new optional dual-track fallback field round-trips
    through [Cascade_config_loader.load_profile_weighted] and that the
    parser preserves backward-compatibility with single-track entries. *)

open Alcotest

module Loader = Masc_mcp.Cascade_config_loader

let with_temp_json contents f =
  let dir = Filename.temp_file "cascade-secondary-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let path = Filename.concat dir "cascade.json" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f path)

let load_first ~name path =
  match Loader.load_profile_weighted ~config_path:path ~name with
  | [] -> failf "no entries for profile %s" name
  | e :: _ -> e

let test_string_entry_has_no_secondary () =
  (* Plain string entries (legacy format) must default secondary = None. *)
  let json = {|{"big_three_models": ["claude_code:auto"]}|} in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check string "model preserved" "claude_code:auto" e.model;
  check (option string) "secondary defaults to None" None e.secondary;
  check (option bool) "secondary_supports_tool_choice defaults to None"
    None e.secondary_supports_tool_choice

let test_object_entry_without_secondary () =
  (* Object entry without [secondary]: must still parse cleanly with
     None. *)
  let json =
    {|{"big_three_models": [
        {"model": "claude_code:auto", "weight": 2}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check string "model preserved" "claude_code:auto" e.model;
  check int "weight preserved" 2 e.weight;
  check (option string) "secondary absent -> None" None e.secondary

let test_object_entry_with_secondary () =
  let json =
    {|{"big_three_models": [
        {"model": "gemini_cli:auto",
         "secondary": "gemini-api:gemini-3-flash",
         "weight": 1}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check string "primary model preserved" "gemini_cli:auto" e.model;
  check (option string) "secondary parsed"
    (Some "gemini-api:gemini-3-flash") e.secondary

let test_secondary_whitespace_trimmed () =
  let json =
    {|{"big_three_models": [
        {"model": "gemini_cli:auto",
         "secondary": "  gemini-api:gemini-3-flash  "}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check (option string) "whitespace trimmed"
    (Some "gemini-api:gemini-3-flash") e.secondary

let test_secondary_empty_string_treated_as_unset () =
  (* Empty string in JSON is parser-equivalent to the field being
     absent.  Prevents an empty secondary from silently turning into
     an invalid provider scheme later. *)
  let json =
    {|{"big_three_models": [
        {"model": "gemini_cli:auto", "secondary": ""}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check (option string) "empty secondary -> None" None e.secondary

let test_secondary_whitespace_only_treated_as_unset () =
  let json =
    {|{"big_three_models": [
        {"model": "gemini_cli:auto", "secondary": "   "}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check (option string) "whitespace-only secondary -> None"
    None e.secondary

let test_secondary_supports_tool_choice_round_trip () =
  let json =
    {|{"big_three_models": [
        {"model": "gemini_cli:auto",
         "secondary": "gemini-api:gemini-3-flash",
         "secondary_supports_tool_choice": true}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check (option bool) "secondary_supports_tool_choice parsed"
    (Some true) e.secondary_supports_tool_choice

let test_secondary_supports_tool_choice_dropped_when_no_secondary () =
  (* Per parse rule: if [secondary] is None, drop any
     [secondary_supports_tool_choice] override silently rather than
     keeping a dangling capability hint.  This matches the materializer
     contract — orphan overrides are rejected at the TOML layer; the
     JSON loader is permissive (typed as final source of truth) and
     simply discards the orphan. *)
  let json =
    {|{"big_three_models": [
        {"model": "gemini_cli:auto",
         "secondary_supports_tool_choice": true}
      ]}|}
  in
  with_temp_json json @@ fun path ->
  let e = load_first ~name:"big_three" path in
  check (option string) "no secondary" None e.secondary;
  check (option bool) "orphan override dropped"
    None e.secondary_supports_tool_choice

let () =
  run "Cascade_secondary_entry_parser"
    [
      ( "backward compatibility",
        [
          test_case "plain string entry: secondary = None" `Quick
            test_string_entry_has_no_secondary;
          test_case "object entry without secondary: secondary = None" `Quick
            test_object_entry_without_secondary;
        ] );
      ( "secondary field parsing",
        [
          test_case "secondary parsed and preserved" `Quick
            test_object_entry_with_secondary;
          test_case "secondary whitespace trimmed" `Quick
            test_secondary_whitespace_trimmed;
          test_case "secondary empty string -> None" `Quick
            test_secondary_empty_string_treated_as_unset;
          test_case "secondary whitespace-only -> None" `Quick
            test_secondary_whitespace_only_treated_as_unset;
          test_case "secondary_supports_tool_choice round-trip" `Quick
            test_secondary_supports_tool_choice_round_trip;
          test_case "orphan secondary_supports_tool_choice dropped" `Quick
            test_secondary_supports_tool_choice_dropped_when_no_secondary;
        ] );
    ]
