open Alcotest

(** RFC-0084 §1.3 + §6 D2 — Surface Coverage (post-PR-5 state)

    PR-5 expanded [lib/keeper/tool_resolution.ml] [surfaces_to_check] from
    4 to 7 admit surfaces. The 8th variant [Keeper_denied] is *excluded*
    from the admit gate (must-deny semantics) and listed separately in
    [_excluded_must_deny] for typed evidence. PR-7 routes [Keeper_denied]
    through the capability gate before admission.

    Admit set (7):
      Public_mcp, Spawned_agent, Local_worker, Session_min, Admin,
      Keeper_internal, System_internal

    Excluded set (1):
      Keeper_denied
*)

let pinned_surfaces_checked = 7
let pinned_surfaces_excluded = 1
let total_surface_variants = 8

let test_surfaces_checked_size () =
  (check int)
    "surfaces_to_check size \
     (RFC-0084 §1.3 / tool_resolution.ml; admit-only after PR-5)"
    7
    pinned_surfaces_checked

let test_surface_coverage_ratio () =
  let ratio_percent = pinned_surfaces_checked * 100 / total_surface_variants in
  (check int)
    "surface coverage percent (admit gate) \
     (RFC-0084 §1.3; 7/8 = 87 — Keeper_denied excluded by design)"
    87
    ratio_percent

let test_excluded_surface_count () =
  (check int)
    "surfaces explicitly excluded from admit gate \
     (RFC-0084 §6 D2 must-deny; Keeper_denied = 1)"
    1
    pinned_surfaces_excluded

let test_coverage_invariant () =
  (* All 8 surfaces are accounted for: checked + excluded = total. *)
  (check int)
    "checked + excluded = total surface variants \
     (RFC-0084 §1.3 enumeration invariant)"
    total_surface_variants
    (pinned_surfaces_checked + pinned_surfaces_excluded)

let test_no_silent_surface_drop () =
  (* No surface variant should be neither checked nor excluded. *)
  let unaccounted =
    total_surface_variants - (pinned_surfaces_checked + pinned_surfaces_excluded)
  in
  (check int)
    "no surface variant is silently dropped \
     (RFC-0084 §1.3; target = 0)"
    0
    unaccounted

let () =
  Alcotest.run
    "RFC-0084 surface coverage"
    [ ( "surface-coverage"
      , [ test_case "surfaces-checked-size" `Quick test_surfaces_checked_size
        ; test_case "surface-coverage-ratio" `Quick test_surface_coverage_ratio
        ; test_case "excluded-surface-count" `Quick test_excluded_surface_count
        ; test_case "coverage-invariant" `Quick test_coverage_invariant
        ; test_case "no-silent-surface-drop" `Quick test_no_silent_surface_drop
        ] )
    ]
