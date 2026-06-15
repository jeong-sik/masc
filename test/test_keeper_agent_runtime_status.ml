(* RFC-0089 (String Classifier to Typed Variant) — typed agent_runtime_status.

   keeper_status_runtime parses the agent-status snapshot blob's "status" field
   into the closed [Masc_domain.agent_status] ADT instead of comparing string
   literals. These tests pin:
   (1) the four canonical labels parse to their constructors,
   (2) keeper_health vocabulary ("idle"/"offline") and garbage parse to [None]
       — these were the dead string arms the old literal matches carried,
   (3) the liveness predicate and surface-status derivation classify the closed
       domain (so removing the dead arms is behavior-preserving on the reachable
       domain and well-defined on the unreachable one). *)

module K = Masc.Keeper_status_runtime
open Alcotest

let blob pairs : Yojson.Safe.t = `Assoc pairs
let status s = blob [ ("status", `String s) ]

let test_known_labels_parse () =
  let check_one label ctor =
    check bool
      (Printf.sprintf "%s parses to constructor" label)
      true
      (K.agent_runtime_status_opt (status label) = Some ctor)
  in
  check_one "active" Masc_domain.Active;
  check_one "busy" Masc_domain.Busy;
  check_one "listening" Masc_domain.Listening;
  check_one "inactive" Masc_domain.Inactive

let test_case_insensitive () =
  check bool "ACTIVE is lowercased before parse" true
    (K.agent_runtime_status_opt (status "ACTIVE") = Some Masc_domain.Active)

let test_outside_domain_is_none () =
  (* "idle"/"offline"/"stale"/"zombie" are keeper_health labels, never
     agent_status. The old literal matches carried them as dead arms; the
     typed parser maps them (and any garbage) to None. *)
  List.iter
    (fun s ->
      check bool
        (Printf.sprintf "%S -> None" s)
        true
        (K.agent_runtime_status_opt (status s) = None))
    [ "idle"; "offline"; "stale"; "zombie"; "garbage"; "" ]

let test_absent_status_is_none () =
  check bool "blob without status field -> None" true
    (K.agent_runtime_status_opt (blob [ ("exists", `Bool true) ]) = None)

let test_live_signal () =
  let live s = blob [ ("status", `String s); ("last_seen_ago_s", `Float 1.0) ] in
  let stale s =
    blob [ ("status", `String s); ("last_seen_ago_s", `Float 9999.0) ]
  in
  check bool "active recent -> live" true
    (K.agent_runtime_has_live_signal (live "active"));
  check bool "listening recent -> live" true
    (K.agent_runtime_has_live_signal (live "listening"));
  check bool "active stale -> not live" false
    (K.agent_runtime_has_live_signal (stale "active"));
  check bool "inactive recent -> not live" false
    (K.agent_runtime_has_live_signal (live "inactive"));
  (* dead-arm removal: "idle" is no longer treated as a live signal *)
  check bool "idle recent -> not live (dead arm gone)" false
    (K.agent_runtime_has_live_signal (live "idle"))

let test_surface_status () =
  let diag h = blob [ ("health_state", `String h) ] in
  check string "healthy + active -> active" "active"
    (K.keeper_surface_status ~agent_status:(status "active")
       ~diagnostic:(diag "healthy"));
  check string "healthy + inactive -> offline" "offline"
    (K.keeper_surface_status ~agent_status:(status "inactive")
       ~diagnostic:(diag "healthy"));
  (* idle blob -> None -> default "active"; the old code surfaced "idle" here,
     but that input is unreachable from parse_agent_status. *)
  check string "healthy + idle-blob -> active (default)" "active"
    (K.keeper_surface_status ~agent_status:(status "idle")
       ~diagnostic:(diag "healthy"));
  check string "kh_idle health -> idle" "idle"
    (K.keeper_surface_status ~agent_status:(status "active")
       ~diagnostic:(diag "idle"));
  check string "kh_stale health -> inactive" "inactive"
    (K.keeper_surface_status ~agent_status:(status "active")
       ~diagnostic:(diag "stale"))

let () =
  run "keeper_agent_runtime_status"
    [
      ( "agent_runtime_status_opt",
        [
          test_case "known labels parse" `Quick test_known_labels_parse;
          test_case "case-insensitive" `Quick test_case_insensitive;
          test_case "outside-domain -> None" `Quick test_outside_domain_is_none;
          test_case "absent -> None" `Quick test_absent_status_is_none;
        ] );
      ( "predicates",
        [
          test_case "live signal" `Quick test_live_signal;
          test_case "surface status" `Quick test_surface_status;
        ] );
    ]
