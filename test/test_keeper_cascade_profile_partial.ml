(** RFC-0058 Phase 8.2: keeper-side validation accepts partial catalogs.

    Reproduces 2026-05-17 incident — a stale binding referencing a removed
    provider used to make
    [Keeper_cascade_profile.declarative_public_catalog_names] return
    [Error "declarative cascade catalog invalid: ..."], dropping keeper
    toml validation onto the [reserved_cascade_names] fallback. With the
    Phase 8 partial-parse surface and Phase 8.2 caller switch, the same
    fixture must surface the valid tier-group names via [Ok names].

    @stability Internal *)

open Alcotest

module KCP = Masc_mcp.Keeper_cascade_profile

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

external test_unsetenv : string -> unit = "masc_test_unsetenv"

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> test_unsetenv name)
    f

(* Same shape as the 2026-05-17 cascade.toml mid-edit state: one stale
   binding plus a valid tier-group. The valid tier-group must reach
   the keeper validator. *)
let partial_cascade_toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[ollama.qwen3]

[tier.local]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.local-group]
tiers = ["local"]
strategy = "failover"

# Stale binding — referenced provider absent.
[ghost.ghost-model]
max-concurrent = 1
|}

let with_temp_cascade_config toml f =
  let root = Filename.temp_file "rfc0058_phase8_2" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let config_dir = Filename.concat root "config" in
  Unix.mkdir config_dir 0o700;
  let cascade_path = Filename.concat config_dir "cascade.toml" in
  write_file cascade_path toml;
  let cleanup () =
    Config_dir_resolver.reset ();
    (try Sys.remove cascade_path with _ -> ());
    (try Unix.rmdir config_dir with _ -> ());
    (try Unix.rmdir root with _ -> ())
  in
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:cleanup
    (fun () -> with_env "MASC_CONFIG_DIR" config_dir (fun () -> f cascade_path))

(* The public API used by keeper toml validation
   (see [Keeper_types_profile] cascade_name validation, line ~807). *)
let test_catalog_names_for_validation_surface_partial () =
  with_temp_cascade_config partial_cascade_toml (fun cascade_path ->
    match KCP.catalog_names_for_validation ~config_path:cascade_path () with
    | Error msg ->
      fail
        (Printf.sprintf
           "keeper validator must accept partial catalog; got Error: %s"
           msg)
    | Ok names ->
      (* This is the exact predicate that prevented the 9 keepers from
         loading on 2026-05-17. Now it accepts the valid subset. *)
      check bool "keeper validator accepts partial catalog" true
        (List.length names > 0);
      check bool "tier-group.local-group surfaces (qualified or stripped)" true
        (List.exists
           (fun n -> n = "tier-group.local-group" || n = "local-group")
           names))

(* [catalog_names] is the read-mostly accessor used by dashboard /
   diagnostic surfaces. It must also surface valid subset. *)
let test_catalog_names_surface_partial () =
  with_temp_cascade_config partial_cascade_toml (fun cascade_path ->
    let names = KCP.catalog_names ~config_path:cascade_path () in
    check bool "catalog_names returns non-empty for partial" true
      (List.length names > 0);
    check bool "tier-group.local-group present" true
      (List.exists (fun n -> n = "local-group") names))

let test_catalog_names_result_surface_partial () =
  with_temp_cascade_config partial_cascade_toml (fun cascade_path ->
    match KCP.catalog_names_result ~config_path:cascade_path () with
    | Error msg ->
      fail
        (Printf.sprintf
           "catalog_names_result must return Ok for partial; got Error: %s"
           msg)
    | Ok names ->
      check bool "result variant accepts partial" true
        (List.length names > 0))

let () =
  run
    "RFC-0058 Phase 8.2: Keeper-side partial catalog acceptance"
    [
      "partial_catalog_consumption",
      [
        test_case
          "catalog_names_for_validation accepts partial (incident gate)"
          `Quick
          test_catalog_names_for_validation_surface_partial;
        test_case
          "catalog_names returns valid subset for partial"
          `Quick
          test_catalog_names_surface_partial;
        test_case
          "catalog_names_result returns Ok for partial"
          `Quick
          test_catalog_names_result_surface_partial;
      ];
    ]
