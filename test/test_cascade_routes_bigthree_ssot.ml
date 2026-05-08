(** Cross-module SSOT drift guard.

    [Keeper_cascade_profile.default_name] must agree with
    [Cascade_defaults.keeper_fallback_profile], the canonical SSOT.

    The former circular dependency ([Keeper_cascade_profile] depends on
    [Cascade_routes]) prevented a single shared constant.  [Cascade_defaults]
    breaks the cycle by living in [lib/cascade/] with no upward deps.

    If you change the literal and this test breaks, change ALL THREE. *)

open Masc_mcp

let ssot = Cascade_defaults.keeper_fallback_profile

let test_drift () =
  Alcotest.(check string)
    "Keeper_cascade_profile.default_name = ssot"
    ssot
    Keeper_cascade_profile.default_name

let test_value_is_big_three () =
  (* Belt-and-braces: pin the canonical string so a stealth rename of
     any module's constant doesn't slip through with all sides
     drifting in sync. *)
  Alcotest.(check string)
    "ssot literal"
    "big_three"
    ssot

let () =
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run "Cascade_routes_bigthree_ssot"
    [
      ( "drift",
        [
          case "cross-module equality" test_drift;
          case "literal pin" test_value_is_big_three;
        ] );
    ]
