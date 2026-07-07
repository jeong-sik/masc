(** Regression for the playground repo [policy_source] label
    ({!Masc.Keeper_sandbox_control.policy_source_basename_of_status}).

    The field previously hardcoded the advisory mapping basename
    (keeper_repo_mappings.toml) for every verdict, so a catalog-sourced denial
    (repo not registered in repositories.toml) reported the wrong config file
    as its source. Keepers then recorded that false cause as durable knowledge
    and stopped touching the registered repo entirely (task-1865 / task-1866).

    The binding allow/deny gate is the catalog (RFC-0312 makes the mapping
    advisory), so every catalog verdict must be sourced from repositories.toml;
    only the mapping-file load failure is sourced from the mapping. Assertions
    compare against the SSOT basenames, not literals, so a rename of either
    config file cannot silently pass a stale expectation. *)

open Alcotest
module Ksc = Masc.Keeper_sandbox_control

let catalog = Masc.Config_dir_resolver.repositories_toml_basename
let mapping = Masc.Keeper_repo_mapping.mappings_toml_basename

let source_of s = Ksc.policy_source_basename_of_status s

let test_catalog_sourced () =
  (* Allow and every deny that the catalog decides are sourced from the
     catalog file, not the advisory mapping. *)
  check string "allowed -> catalog" catalog (source_of Ksc.Policy_allowed);
  check string "unregistered -> catalog" catalog
    (source_of Ksc.Policy_unregistered_repository);
  check string "identity mismatch -> catalog" catalog
    (source_of Ksc.Policy_repository_identity_mismatch);
  check string "store error -> catalog" catalog
    (source_of Ksc.Policy_repository_store_error)
;;

let test_mapping_sourced () =
  (* Only the advisory mapping's own load failure is sourced from the mapping
     file. *)
  check string "mapping load error -> mapping" mapping
    (source_of Ksc.Policy_mapping_load_error)
;;

let test_catalog_and_mapping_are_distinct () =
  (* The bug was invisible because both once resolved to the mapping basename;
     pin that the two sources are different files so a regression that collapses
     them fails here. *)
  check bool "catalog basename differs from mapping basename" true
    (not (String.equal catalog mapping))
;;

let () =
  run "policy_source_of_status"
    [ ( "source-of-truth",
        [ test_case "catalog verdicts are sourced from repositories.toml" `Quick
            test_catalog_sourced
        ; test_case "mapping load failure is sourced from keeper_repo_mappings.toml"
            `Quick test_mapping_sourced
        ; test_case "catalog and mapping basenames are distinct files" `Quick
            test_catalog_and_mapping_are_distinct
        ] )
    ]
;;
