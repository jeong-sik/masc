(** test_keeper_cascade_profile_bridge — Unit tests for the
    [catalog_metadata_query] typed bridge.

    The bridge has three control-flow origins, mirroring the three
    [Error] sites in the legacy [catalog_metadata_result]:

    {ul
    {- [Catalog_path_not_resolved] — the resolver returned [None].}
    {- [Catalog_load_failed _] — the loader surfaced a file or
       parse error.}
    {- [Catalog_metadata_invalid _] — the materialized JSON did not
       produce a valid catalog metadata record.}}

    These tests cover the first two branches directly. The third
    requires a TOML that loads cleanly but materializes invalid
    metadata; constructing that fixture in isolation would duplicate
    too much of the loader's internals, so it is exercised
    indirectly via integration tests against real fixtures (the
    catalog metadata builder is already covered by
    [test_keeper_cascade_profile_partial]). *)

open Masc_mcp
module P = Keeper_cascade_profile

let test_path_not_resolved () =
  (* config_path = Some "/nonexistent/...." would trigger
     Catalog_load_failed (file missing). To exercise
     Catalog_path_not_resolved we leave config_path unset AND clear
     MASC_CONFIG_DIR so Config_dir_resolver.cascade_path_opt ()
     returns None. *)
  let original = try Some (Sys.getenv "MASC_CONFIG_DIR") with Not_found -> None in
  Unix.putenv "MASC_CONFIG_DIR" "";
  let result = P.catalog_metadata_query () in
  (match original with
   | Some v -> Unix.putenv "MASC_CONFIG_DIR" v
   | None -> Unix.putenv "MASC_CONFIG_DIR" "");
  Alcotest.(check bool) "Catalog_path_not_resolved when no config dir" true
    (match result with
     | Catalog_unavailable { reason = Catalog_path_not_resolved; _ } -> true
     | _ -> false)

let test_load_failed_on_missing_file () =
  let bogus = "/tmp/masc-mcp-test-nonexistent-cascade-bridge.toml" in
  (* Ensure the file does NOT exist. *)
  (try Sys.remove bogus with _ -> ());
  let result = P.catalog_metadata_query ~config_path:bogus () in
  Alcotest.(check bool) "Catalog_load_failed when file is missing" true
    (match result with
     | Catalog_unavailable { reason = Catalog_load_failed _; _ } -> true
     | _ -> false)

let test_reason_to_string_total () =
  (* All three constructors map to a non-empty short token suitable
     for metric labels. *)
  Alcotest.(check string) "path_not_resolved"
    "path_not_resolved"
    (P.catalog_unavailable_reason_to_string Catalog_path_not_resolved);
  Alcotest.(check string) "load_failed"
    "load_failed"
    (P.catalog_unavailable_reason_to_string (Catalog_load_failed "msg"));
  Alcotest.(check string) "metadata_invalid"
    "metadata_invalid"
    (P.catalog_unavailable_reason_to_string (Catalog_metadata_invalid "msg"))

let () =
  Alcotest.run "keeper_cascade_profile_bridge"
    [
      ( "catalog_metadata_query"
      , [
          Alcotest.test_case "path_not_resolved" `Quick test_path_not_resolved;
          Alcotest.test_case "load_failed on missing file" `Quick
            test_load_failed_on_missing_file;
        ] );
      ( "reason_to_string"
      , [
          Alcotest.test_case "total over all reasons" `Quick test_reason_to_string_total;
        ] );
    ]
