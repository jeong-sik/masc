(* RFC-0089 (String Classifier to Typed Variant) — keeper surface_status.

   keeper_surface_status derives a display status from keeper_health and emits
   it as a string; the server row patcher re-classifies that string. These
   tests pin:
   (1) surface_status_of_string_opt parses the three labels and rejects values
       outside the domain ("paused" override, drift, garbage),
   (2) to_string is the inverse on the closed domain,
   (3) keeper_surface_status produces the expected wire string for each
       keeper-health state. *)

module K = Masc.Keeper_status_runtime
open Alcotest

let blob pairs : Yojson.Safe.t = `Assoc pairs
let diag h = blob [ ("health_state", `String h) ]

let test_of_string_known () =
  let one label ctor =
    check bool
      (Printf.sprintf "%s parses" label)
      true
      (K.surface_status_of_string_opt label = Some ctor)
  in
  one "active" K.Surface_active;
  one "offline" K.Surface_offline;
  one "idle" K.Surface_idle;
  check bool "case + whitespace insensitive" true
    (K.surface_status_of_string_opt "  OFFLINE " = Some K.Surface_offline)

let test_of_string_outside_domain () =
  (* "paused" is an operator override, not a surface_status; the rest are
     drift/garbage. All must parse to None. *)
  List.iter
    (fun s ->
      check bool
        (Printf.sprintf "%S -> None" s)
        true
        (K.surface_status_of_string_opt s = None))
    [ "paused"; "error"; "unknown"; "" ]

let test_to_string_inverse () =
  List.iter
    (fun ctor ->
      check bool "to_string then of_string round-trips" true
        (K.surface_status_of_string_opt (K.surface_status_to_string ctor)
        = Some ctor))
    [
      K.Surface_active;
      K.Surface_offline;
      K.Surface_idle;
    ]

let test_producer_behavior () =
  let surface health = K.keeper_surface_status ~diagnostic:(diag health) in
  check string "healthy -> active" "active" (surface "healthy");
  check string "idle health -> idle" "idle"
    (surface "idle");
  check string "offline health -> offline" "offline"
    (surface "offline")

(* [health] and [status] answer from different vocabularies. Feeding one
   diagnostic to both readers is the only way to see that: a row built from
   a fresh workspace spells both fields "offline", legitimately. *)
let test_two_readers_of_one_diagnostic_differ_on_healthy () =
  let d = diag "healthy" in
  check string "health reader returns healthy unchanged" "healthy"
    (K.keeper_health_to_string
       (K.keeper_diagnostic_health ~diagnostic:d ~source:"test"));
  check string "surface spells the same reading active" "active"
    (K.keeper_surface_status ~diagnostic:d)

let test_unreadable_health_is_offline_not_healthy () =
  (* A diagnostic this build cannot read must not resolve to a word that looks
     fine. Three shapes: an unknown spelling, a missing field, and a field of
     the wrong type. *)
  let reads_offline label d =
    check string
      (Printf.sprintf "%s resolves to offline" label)
      "offline"
      (K.keeper_health_to_string
         (K.keeper_diagnostic_health ~diagnostic:d ~source:"test"))
  in
  reads_offline "unknown spelling" (diag "sleepy");
  reads_offline "absent field" (blob []);
  reads_offline "wrong type" (blob [ ("health_state", `Int 3) ])
;;

let () =
  run "keeper_surface_status"
    [
      ( "surface_status_of_string_opt",
        [
          test_case "known labels" `Quick test_of_string_known;
          test_case "outside domain -> None" `Quick test_of_string_outside_domain;
          test_case "to_string inverse" `Quick test_to_string_inverse;
        ] );
      ( "keeper_surface_status",
        [
          test_case "producer behavior preserved" `Quick test_producer_behavior;
          test_case "two readers of one diagnostic differ on healthy" `Quick
            test_two_readers_of_one_diagnostic_differ_on_healthy;
        ] );
      ( "keeper_diagnostic_health",
        [
          test_case "unreadable resolves to offline" `Quick
            test_unreadable_health_is_offline_not_healthy;
        ] );
    ]
