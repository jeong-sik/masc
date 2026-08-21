(* RFC-0089 (String Classifier to Typed Variant) — keeper surface_status.

   keeper_surface_status derives a display status from keeper_health and emits
   it as a string; the server row patcher re-classifies that string. These
   tests pin:
   (1) surface_status_of_string_opt parses the six labels and rejects values
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
  one "busy" K.Surface_busy;
  one "listening" K.Surface_listening;
  one "inactive" K.Surface_inactive;
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
    [ "paused"; "error"; "stale"; "zombie"; "unknown"; "" ]

let test_to_string_inverse () =
  List.iter
    (fun ctor ->
      check bool "to_string then of_string round-trips" true
        (K.surface_status_of_string_opt (K.surface_status_to_string ctor)
        = Some ctor))
    [
      K.Surface_active;
      K.Surface_busy;
      K.Surface_listening;
      K.Surface_inactive;
      K.Surface_offline;
      K.Surface_idle;
    ]

let test_producer_behavior () =
  let surface health = K.keeper_surface_status ~diagnostic:(diag health) in
  check string "healthy -> active" "active" (surface "healthy");
  check string "idle health -> idle" "idle"
    (surface "idle");
  check string "stale health -> inactive" "inactive"
    (surface "stale");
  check string "offline health -> offline" "offline"
    (surface "offline")

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
        [ test_case "producer behavior preserved" `Quick test_producer_behavior ]
      );
    ]
