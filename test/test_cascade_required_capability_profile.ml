(** RFC-0027 PR-2 / RFC-0058: cascade [required_capability_profile] parser.

    Verifies the optional field round-trips through
    [Cascade_config_loader.load_catalog] and that an unknown profile
    string fails closed (Error) instead of falling back to None.

    @since RFC-0058 migrated from closed variant to string-based profiles
    @since RFC-0058 §9.4 fixtures migrated from cascade.json to cascade.toml *)

open Alcotest

module Loader = Masc_mcp.Cascade_config_loader
module CP = Masc_mcp.Cascade_capability_profile

(* RFC-0058 §9 made cascade.toml the on-disk SSOT.  Tests write TOML and
   pass the conventional cascade.json sibling path through the loader;
   the materializer resolves the .toml automatically. *)
let with_temp_toml contents f =
  let dir = Filename.temp_file "cascade-rcp-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let toml_path = Filename.concat dir "cascade.toml" in
  let oc = open_out toml_path in
  output_string oc contents;
  close_out oc;
  let json_path = Filename.concat dir "cascade.json" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove toml_path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f json_path)

let entry_named entries name =
  List.find_opt (fun (e : Loader.catalog_entry) -> e.name = name) entries

let test_profile_set_to_known_value () =
  let toml =
    {|[big_three]
models = ["claude_code:auto"]
required_capability_profile = "tool_strict"
|}
  in
  with_temp_toml toml @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Error msg -> failf "load failed: %s" msg
  | Ok entries ->
      (match entry_named entries "big_three" with
       | None -> failf "big_three entry missing"
       | Some e ->
           check (option string) "tool_strict parsed"
             (Some "tool_strict")
             e.required_capability_profile)

let test_profile_field_omitted_defaults_to_none () =
  let toml =
    {|[big_three]
models = ["claude_code:auto"]
|}
  in
  with_temp_toml toml @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Error msg -> failf "load failed: %s" msg
  | Ok entries ->
      (match entry_named entries "big_three" with
       | None -> failf "big_three entry missing"
       | Some e ->
           check (option string) "field omitted -> None" None
             e.required_capability_profile)

let test_profile_empty_string_treated_as_unset () =
  (* The materializer rejects empty/whitespace-only
     [required_capability_profile] strings at the schema layer
     ([trimmed_nonempty_string]).  Exercise the materializer's
     fail-closed surface instead of pretending an empty value reaches
     the loader. *)
  let toml =
    {|[big_three]
models = ["claude_code:auto"]
required_capability_profile = ""
|}
  in
  with_temp_toml toml @@ fun path ->
  match Loader.load_catalog ~config_path:path with
  | Ok _ -> fail "expected materializer to reject empty required_capability_profile"
  | Error msg ->
      check bool "error message names the offending field" true
        (Astring.String.is_infix
           ~affix:"required_capability_profile" msg)

let test_unknown_profile_fails_closed () =
  let toml =
    {|[big_three]
models = ["claude_code:auto"]
required_capability_profile = "no_such_profile"
|}
  in
  with_temp_toml toml @@ fun path ->
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
    (fun name ->
      let toml =
        Printf.sprintf
          {|[sample]
models = ["claude_code:auto"]
required_capability_profile = "%s"
|}
          name
      in
      with_temp_toml toml @@ fun path ->
      match Loader.load_catalog ~config_path:path with
      | Error msg -> failf "load failed for profile %s: %s" name msg
      | Ok entries ->
          (match entry_named entries "sample" with
           | None -> failf "sample entry missing for profile %s" name
           | Some e ->
               check (option string)
                 (Printf.sprintf "%s parsed" name)
                 (Some name) e.required_capability_profile))
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
          test_case "empty string -> materializer rejects" `Quick
            test_profile_empty_string_treated_as_unset;
          test_case "unknown value -> Error (fail-closed)" `Quick
            test_unknown_profile_fails_closed;
          test_case "every known profile name round-trips"
            `Quick test_each_known_profile_parses;
        ] );
    ]
