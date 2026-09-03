(* A paused keeper retains recovery once a pass, forever; the pass that
   lands on a full day of them is the one that warns. *)

open Alcotest
open Masc

let test_day_boundary () =
  check bool "the first pass stays quiet" false
    (Server_bootstrap_maintenance.retention_becomes_warning 1);
  check bool "the pass before a day stays quiet" false
    (Server_bootstrap_maintenance.retention_becomes_warning 1439);
  check bool "a full day warns" true
    (Server_bootstrap_maintenance.retention_becomes_warning 1440);
  check bool "two days warn again" true
    (Server_bootstrap_maintenance.retention_becomes_warning 2880);
  check bool "zero never warns" false
    Server_bootstrap_maintenance.retention_becomes_warning 0
;;

let () =
  run "bootstrap_retention_warning"
    [ ("boundary", [ test_case "day boundary" `Quick test_day_boundary ]) ]
;;
