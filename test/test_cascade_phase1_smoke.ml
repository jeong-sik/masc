(** RFC-0058 Phase 1: runtime smoke test for TOML-declared profiles.

    Verifies that [register_declared_profiles_from_json] fires during
    [load_catalog] when the JSON contains a ["profiles"] section, and that
    the declared profile resolves and satisfies correctly.

    Generates a minimal cascade config fixture at runtime under [.tmp/].

    @since RFC-0058 Phase 1 *)

open Alcotest
module CP = Masc_mcp.Cascade_capability_profile
module CCL = Masc_mcp.Cascade_config_loader
module PTS = Masc_mcp.Provider_tool_support

let config_dir = ".tmp/phase1-smoke"
let config_path = config_dir ^ "/cascade.json"

let make_caps ~it ~itc ~rmt ~rte ~rmh : PTS.capabilities =
  { PTS.supports_inline_tools = it;
    supports_inline_tool_choice = itc;
    supports_runtime_mcp_tools = rmt;
    supports_runtime_tool_events = rte;
    supports_runtime_mcp_http_headers = rmh }

let claude_code_caps =
  make_caps ~it:false ~itc:false ~rmt:true ~rte:true ~rmh:true

let glm_http_caps =
  make_caps ~it:true ~itc:true ~rmt:false ~rte:false ~rmh:false

let all_on =
  make_caps ~it:true ~itc:true ~rmt:true ~rte:true ~rmh:true

let all_off =
  make_caps ~it:false ~itc:false ~rmt:false ~rte:false ~rmh:false

(** Minimal JSON fixture: two catalog entries + a declared profile. *)
let write_fixture () =
  let json = {|
{
  "profiles": {
    "strict_plus": {
      "required_capabilities": ["inline_tools", "runtime_mcp_tools"]
    }
  },
  "big_three_models": ["test:model-a"],
  "big_three_temperature": 0.5,
  "big_three_max_tokens": 1024,
  "big_three_thinking_enabled": false,
  "big_three_keeper_assignable": true,
  "big_three_fallback_cascade": null,
  "test_strict_plus_models": ["test:model-b"],
  "test_strict_plus_temperature": 0.7,
  "test_strict_plus_max_tokens": 2048,
  "test_strict_plus_thinking_enabled": false,
  "test_strict_plus_keeper_assignable": true,
  "test_strict_plus_required_capability_profile": "strict_plus"
}
|} in
  (try Unix.mkdir ".tmp" 0o755 with Unix.Unix_error _ -> ());
  (try Unix.mkdir config_dir 0o755 with Unix.Unix_error _ -> ());
  let oc = open_out config_path in
  output_string oc json;
  close_out oc

let test_load_catalog_succeeds () =
  match CCL.load_catalog ~config_path with
  | Error msg ->
      failf "load_catalog failed for %s: %s" config_path msg
  | Ok entries ->
      let names = List.map (fun (e : CCL.catalog_entry) -> e.name) entries in
      check bool "big_three present" true (List.mem "big_three" names);
      check bool "test_strict_plus present" true
        (List.mem "test_strict_plus" names)

let test_declared_profile_in_registry () =
  let names = CP.declared_profile_names () in
  check bool "strict_plus in declared profiles" true
    (List.mem "strict_plus" names)

let test_declared_profile_satisfaction () =
  check bool "claude_code does NOT satisfy strict_plus (no inline_tools)"
    false
    (CP.provider_satisfies_named_profile "strict_plus" claude_code_caps);
  check bool "glm_http does NOT satisfy strict_plus (no runtime_mcp)"
    false
    (CP.provider_satisfies_named_profile "strict_plus" glm_http_caps);
  check bool "all_on satisfies strict_plus" true
    (CP.provider_satisfies_named_profile "strict_plus" all_on);
  check bool "all_off does not satisfy strict_plus" false
    (CP.provider_satisfies_named_profile "strict_plus" all_off)

let test_catalog_entry_required_profile () =
  match CCL.load_catalog ~config_path with
  | Error msg ->
      failf "load_catalog failed: %s" msg
  | Ok entries ->
      let test_entry =
        List.find_opt (fun (e : CCL.catalog_entry) ->
          String.equal e.name "test_strict_plus") entries
      in
      (match test_entry with
       | None -> failf "test_strict_plus entry not found in catalog"
       | Some entry ->
           check (option string) "required_capability_profile = strict_plus"
             (Some "strict_plus")
             entry.required_capability_profile)

let test_builtin_profiles_unaffected () =
  check bool "tool_strict (built-in) still works with all_on" true
    (CP.provider_satisfies_named_profile "tool_strict" all_on);
  check bool "lite (built-in) accepts claude_code" true
    (CP.provider_satisfies_named_profile "lite" claude_code_caps);
  check bool "local (built-in) accepts all_off" true
    (CP.provider_satisfies_named_profile "local" all_off)

let () =
  write_fixture ();
  let _ = CCL.load_catalog ~config_path in
  run "RFC-0058 Phase 1 smoke"
    [
      ( "catalog loading",
        [
          test_case "load_catalog succeeds with profiles section" `Quick
            test_load_catalog_succeeds;
          test_case "catalog entry required_capability_profile" `Quick
            test_catalog_entry_required_profile;
        ] );
      ( "declared profile registry",
        [
          test_case "strict_plus in declared_profile_names" `Quick
            test_declared_profile_in_registry;
          test_case "strict_plus satisfaction" `Quick
            test_declared_profile_satisfaction;
        ] );
      ( "built-in profiles unaffected",
        [
          test_case "built-in profiles still resolve correctly" `Quick
            test_builtin_profiles_unaffected;
        ] );
    ]
