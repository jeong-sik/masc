(** Per-keeper runtime stores live at
    [<keepers>/<name>/<store>], and Common.keeper_runtime_store_dirname is
    the closed variant that names each [<store>].

    Producers, readers, retention, and telemetry once built these names from
    string literals independently. These tests pin the closed set and its
    spellings so adding or renaming a store updates the shared owner first. *)

open Alcotest

module C = Common

let name s = C.keeper_runtime_store_dirname s

(* Listed here rather than read from Common: a new variant must be added to
   this list by hand, which is the point — the cases below then cover it. *)
let all_stores =
  [ C.Keeper_tool_usage
  ; C.Keeper_runtime_manifests
  ; C.Keeper_metrics
  ; C.Keeper_crash_events
  ; C.Keeper_execution_receipts
  ; C.Keeper_turn_records
  ; C.Keeper_raw_traces
  ; C.Keeper_reaction_ledger
  ; C.Keeper_trajectories
  ]
;;

let names_are_unchanged () =
  check string "metrics" "metrics" (name C.Keeper_metrics);
  check string "crash events" "crash-events" (name C.Keeper_crash_events);
  check string "turn records" "turn-records" (name C.Keeper_turn_records);
  check string "raw traces" "raw-traces" (name C.Keeper_raw_traces);
  check string "execution receipts" "execution-receipts" (name C.Keeper_execution_receipts);
  check string "reaction ledger" "reaction-ledger" (name C.Keeper_reaction_ledger);
  check string "runtime manifests" "runtime-manifests" (name C.Keeper_runtime_manifests);
  check string "tool usage" "tool_usage" (name C.Keeper_tool_usage);
  check string "trajectories" "trajectories" (name C.Keeper_trajectories)
;;

(* Two stores sharing a directory name would collide under one keeper. *)
let names_are_distinct () =
  let all = List.map name all_stores in
  let unique = List.sort_uniq String.compare all in
  check int "no duplicate store directory" (List.length all) (List.length unique)
;;

(* A name that arrived with a separator already in it, as "/metrics" once did,
   composes a different path than Filename.concat produces. *)
let names_carry_no_separator () =
  List.iter
    (fun store ->
       let n = name store in
       check bool ("no separator in " ^ n) false (String.contains n '/'))
    all_stores
;;

let () =
  run
    "keeper_store_dirname"
    [ ( "store names"
      , [ test_case "names are unchanged" `Quick names_are_unchanged
        ; test_case "names are distinct" `Quick names_are_distinct
        ; test_case "names carry no separator" `Quick names_carry_no_separator
        ] )
    ]
;;
