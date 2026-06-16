(* RFC-0089 (String Classifier to Typed Variant) — keeper surface_status.

   keeper_surface_status derives a display status from (keeper_health x
   agent_status) and emits it as a string; the operator align step and the
   server row patcher re-classify that string by literal. These tests pin:
   (1) surface_status_of_string_opt parses the six labels and rejects values
       outside the domain ("paused" override, drift, garbage),
   (2) to_string is the inverse on the closed domain,
   (3) keeper_surface_status produces the expected wire string for each
       (keeper_health x agent_status) combination — behavior preserved. *)

module K = Masc.Keeper_status_runtime
open Alcotest

let blob pairs : Yojson.Safe.t = `Assoc pairs
let diag h = blob [ ("health_state", `String h) ]
let status s = blob [ ("status", `String s) ]

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
  (* "paused" is a control-plane override, not a surface_status; the rest are
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
  let surface ~health ~agent_status =
    K.keeper_surface_status ~agent_status ~diagnostic:(diag health)
  in
  (* KH_healthy maps agent_status through *)
  check string "healthy+active -> active" "active"
    (surface ~health:"healthy" ~agent_status:(status "active"));
  check string "healthy+busy -> busy" "busy"
    (surface ~health:"healthy" ~agent_status:(status "busy"));
  check string "healthy+listening -> listening" "listening"
    (surface ~health:"healthy" ~agent_status:(status "listening"));
  check string "healthy+inactive -> offline" "offline"
    (surface ~health:"healthy" ~agent_status:(status "inactive"));
  check string "healthy+unknown -> active (default)" "active"
    (surface ~health:"healthy" ~agent_status:(status "idle"));
  (* keeper_health drives the rest regardless of agent_status *)
  check string "idle health -> idle" "idle"
    (surface ~health:"idle" ~agent_status:(status "active"));
  check string "stale health -> inactive" "inactive"
    (surface ~health:"stale" ~agent_status:(status "active"));
  check string "offline health -> offline" "offline"
    (surface ~health:"offline" ~agent_status:(status "active"))

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
