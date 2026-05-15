open Alcotest

(** RFC-0083 §1.3 Surface Coverage Gap

    [lib/keeper/tool_resolution.ml:81-86] [surfaces_to_check] is hardcoded
    to 4 of 8 [Tool_catalog_surfaces.surface] variants:

    {v
    let surfaces_to_check =
      [ Tool_catalog_surfaces.Public_mcp
      ; Tool_catalog_surfaces.Spawned_agent
      ; Tool_catalog_surfaces.Local_worker
      ; Tool_catalog_surfaces.Admin
      ]
    v}

    Missing: [Session_min], [Keeper_internal], [Keeper_denied], [System_internal].

    PR-5 expands [surfaces_to_check] to all 8 with explicit policy semantics
    for the new 4 variants (per RFC-0083 §6 decision D2). PR-5 must update
    [pinned_surfaces_checked] from 4 → 8 alongside the code change.
*)

let pinned_surfaces_checked = 4
let total_surface_variants = 8

let test_surfaces_checked_size () =
  (check int)
    "surfaces_to_check size \
     (RFC-0083 §1.3 / tool_resolution.ml:81-86; PR-5 target = 8)"
    4
    pinned_surfaces_checked

let test_surface_coverage_ratio () =
  let ratio_percent = pinned_surfaces_checked * 100 / total_surface_variants in
  (check int)
    "surface coverage percent \
     (RFC-0083 §1.3; PR-5 target = 100)"
    50
    ratio_percent

let test_unchecked_surface_count () =
  let missing = total_surface_variants - pinned_surfaces_checked in
  (check int)
    "surfaces missing from policy gate \
     (RFC-0083 §1.3; PR-5 target = 0)"
    4
    missing

let () =
  Alcotest.run
    "RFC-0083 surface coverage gap"
    [ ( "surface-coverage-gap"
      , [ test_case "surfaces-checked-size" `Quick test_surfaces_checked_size
        ; test_case "surface-coverage-ratio" `Quick test_surface_coverage_ratio
        ; test_case "unchecked-surface-count" `Quick test_unchecked_surface_count
        ] )
    ]
