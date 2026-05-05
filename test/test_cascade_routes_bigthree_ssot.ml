(** Cross-module SSOT drift guard.

    [Cascade_routes.keeper_default_last_resort_profile] must agree with
    [Keeper_cascade_profile.default_name] at all times.  These two strings
    cannot reference a single SSOT directly because [Keeper_cascade_profile]
    already depends on [Cascade_routes] (cycle prevention), so this test is
    the guard that catches drift.

    If you change either constant and this test breaks, change BOTH. *)

open Masc_mcp

let test_drift () =
  Alcotest.(check string)
    "Cascade_routes.keeper_default_last_resort_profile = \
     Keeper_cascade_profile.default_name"
    Keeper_cascade_profile.default_name
    Cascade_routes.keeper_default_last_resort_profile

let test_value_is_big_three () =
  (* Belt-and-braces: pin both ends to the literal so a stealth rename of
     either module's constant doesn't slip through with both sides
     drifting in sync. *)
  Alcotest.(check string)
    "Cascade_routes side"
    "big_three"
    Cascade_routes.keeper_default_last_resort_profile;
  Alcotest.(check string)
    "Keeper_cascade_profile side"
    "big_three"
    Keeper_cascade_profile.default_name

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
