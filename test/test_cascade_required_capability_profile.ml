(** RFC-0027 PR-2: cascade.json [_required_capability_profile] parser.

    Verifies the new optional field round-trips through
    [Cascade_config_loader.load_catalog] and that an unknown profile
    string fails closed (Error) instead of falling back to None. *)

open Alcotest

module Loader = Masc_mcp.Cascade_config_loader
module CP = Masc_mcp.Cascade_capability_profile

let with_temp_json contents f =
  let dir = Filename.temp_file "cascade-rcp-" "" in
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

let entry_named entries name =
  List.find_opt (fun (e : Loader.catalog_entry) -> e.name = name) entries

let pp_profile_opt fmt = function
  | None -> Format.pp_print_string fmt "None"
  | Some p ->
      Format.pp_print_string fmt
        (Printf.sprintf "Some %s" (CP.profile_to_string p))

let profile_opt =
  testable pp_profile_opt ( = )

let test_profile_set_to_known_value () =
  let json =
    {|{"big_three_models": ["claude_code:auto"],
        "big_three_required_capability_profile": "tool_strict"}|}
  in
  with_temp_json json @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Error msg -> failf "load failed: %s" msg
  | Ok entries ->
      (match entry_named entries "big_three" with
       | None -> failf "big_three entry missing"
       | Some e ->
           check profile_opt "tool_strict parsed"
             (Some CP.Tool_strict)
             e.required_capability_profile)

let test_profile_field_omitted_defaults_to_none () =
  let json = {|{"big_three_models": ["claude_code:auto"]}|} in
  with_temp_json json @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Error msg -> failf "load failed: %s" msg
  | Ok entries ->
      (match entry_named entries "big_three" with
       | None -> failf "big_three entry missing"
       | Some e ->
           check profile_opt "field omitted -> None" None
             e.required_capability_profile)

let test_profile_empty_string_treated_as_unset () =
  let json =
    {|{"big_three_models": ["claude_code:auto"],
        "big_three_required_capability_profile": ""}|}
  in
  with_temp_json json @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Error msg -> failf "load failed on empty string: %s" msg
  | Ok entries ->
      (match entry_named entries "big_three" with
       | None -> failf "big_three entry missing"
       | Some e ->
           check profile_opt "empty string -> None" None
             e.required_capability_profile)

let test_unknown_profile_fails_closed () =
  let json =
    {|{"big_three_models": ["claude_code:auto"],
        "big_three_required_capability_profile": "no_such_profile"}|}
  in
  with_temp_json json @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Ok _ ->
      fail "load should have failed for unknown profile"
  | Error msg ->
      check bool "error message names the bad profile" true
        (Astring.String.is_infix ~affix:"no_such_profile" msg);
      check bool "error message lists known profiles" true
        (Astring.String.is_infix ~affix:"tool_strict" msg)

let test_each_known_profile_parses () =
  List.iter
    (fun p ->
      let s = CP.profile_to_string p in
      let json =
        Printf.sprintf
          {|{"sample_models": ["claude_code:auto"],
            "sample_required_capability_profile": "%s"}|}
          s
      in
      with_temp_json json @@ fun path ->
      match Loader.load_catalog ~config_path:path with
      | Error msg -> failf "load failed for profile %s: %s" s msg
      | Ok entries ->
          (match entry_named entries "sample" with
           | None -> failf "sample entry missing for profile %s" s
           | Some e ->
               check profile_opt
                 (Printf.sprintf "%s parsed" s)
                 (Some p) e.required_capability_profile))
    CP.all_profiles

let () =
  run "Cascade_required_capability_profile_parser"
    [
      ( "field parsing",
        [
          test_case "known value -> Some profile" `Quick
            test_profile_set_to_known_value;
          test_case "field omitted -> None" `Quick
            test_profile_field_omitted_defaults_to_none;
          test_case "empty string -> None" `Quick
            test_profile_empty_string_treated_as_unset;
          test_case "unknown value -> Error (fail-closed)" `Quick
            test_unknown_profile_fails_closed;
          test_case "every Cascade_capability_profile.profile round-trips"
            `Quick test_each_known_profile_parses;
        ] );
    ]
