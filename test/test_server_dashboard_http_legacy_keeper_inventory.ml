(** Regression tests for legacy [.masc/keepers] inventory. *)

module Inventory = Server_dashboard_http_legacy_keeper_inventory

let fresh_dir prefix = Filename.temp_dir prefix ""

let ensure_dir path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let write_file path contents =
  let oc = Out_channel.open_text path in
  Fun.protect
    ~finally:(fun () -> Out_channel.close oc)
    (fun () -> Out_channel.output_string oc contents)
;;

let assoc_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let int_field name json =
  match assoc_field name json with
  | Some (`Int n) -> n
  | _ -> Alcotest.failf "expected int field %S" name
;;

let bool_field name json =
  match assoc_field name json with
  | Some (`Bool b) -> b
  | _ -> Alcotest.failf "expected bool field %S" name
;;

let object_field name json =
  match assoc_field name json with
  | Some (`Assoc _ as obj) -> obj
  | _ -> Alcotest.failf "expected object field %S" name
;;

let list_field name json =
  match assoc_field name json with
  | Some (`List xs) -> xs
  | _ -> Alcotest.failf "expected list field %S" name
;;

let class_count class_name json =
  let totals = object_field "class_totals" json in
  match assoc_field class_name totals with
  | Some obj -> int_field "count" obj
  | None -> Alcotest.failf "missing class total %S" class_name
;;

let entry_classes json =
  list_field "entries" json
  |> List.filter_map (function
    | `Assoc fields ->
      (match List.assoc_opt "path" fields, List.assoc_opt "class" fields with
       | Some (`String path), Some (`String cls) -> Some (path, cls)
       | _ -> None)
    | _ -> None)
;;

let test_classifies_legacy_paths_and_dry_run_candidates () =
  let base = fresh_dir "masc-legacy-keeper-inventory" in
  let legacy = Filename.concat (Filename.concat base ".masc") "keepers" in
  let current = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ensure_dir (Filename.concat base ".masc");
  ensure_dir legacy;
  ensure_dir (Filename.dirname current);
  ensure_dir current;
  ensure_dir (Filename.concat legacy "alpha");
  ensure_dir (Filename.concat legacy "alpha/metrics");
  ensure_dir (Filename.concat current "alpha");
  write_file (Filename.concat legacy "alpha/.atomic_dead.tmp") "orphan";
  write_file (Filename.concat legacy "PYEOF") "marker";
  write_file (Filename.concat legacy "alpha/old.backup") "backup";
  write_file (Filename.concat legacy "alpha/facts.jsonl") "{}\n";
  write_file (Filename.concat current "alpha/facts.jsonl") "{}\n";
  write_file (Filename.concat legacy "alpha/metrics/2026.jsonl") "{}\n";
  write_file (Filename.concat legacy "mystery.bin") "?";
  let json =
    Inventory.legacy_keeper_inventory_http_json
      ~base_path:base
      ~max_depth:4
      ~max_entries:100
      ()
  in
  Alcotest.(check bool) "inventory is read-only" true (bool_field "read_only" json);
  Alcotest.(check bool) "not truncated" false (bool_field "truncated" json);
  Alcotest.(check int) "orphaned count" 2 (class_count "orphaned" json);
  Alcotest.(check int) "backup count" 1 (class_count "backup" json);
  Alcotest.(check int) "migrated count" 1 (class_count "migrated" json);
  Alcotest.(check bool)
    "live metric classified"
    true
    (List.mem ("alpha/metrics/2026.jsonl", "live") (entry_classes json));
  Alcotest.(check bool)
    "unknown file classified"
    true
    (List.mem ("mystery.bin", "unknown") (entry_classes json));
  let plan = object_field "dry_run_cleanup_plan" json in
  Alcotest.(check bool) "delete disabled" false (bool_field "delete_allowed" plan);
  Alcotest.(check bool)
    "operator approval required"
    true
    (bool_field "requires_operator_approval" plan);
  Alcotest.(check int) "cleanup candidates" 3 (int_field "candidate_count" plan)
;;

let test_scan_cap_marks_truncation () =
  let base = fresh_dir "masc-legacy-keeper-inventory-cap" in
  let legacy = Filename.concat (Filename.concat base ".masc") "keepers" in
  ensure_dir (Filename.concat base ".masc");
  ensure_dir legacy;
  write_file (Filename.concat legacy "a.tmp") "a";
  write_file (Filename.concat legacy "b.tmp") "b";
  let json =
    Inventory.legacy_keeper_inventory_http_json
      ~base_path:base
      ~max_depth:4
      ~max_entries:1
      ()
  in
  Alcotest.(check bool) "truncated" true (bool_field "truncated" json);
  Alcotest.(check int) "visited cap" 1 (int_field "visited_entries" json)
;;

let () =
  Alcotest.run
    "server_dashboard_http_legacy_keeper_inventory"
    [ ( "inventory"
      , [ Alcotest.test_case
            "classifies legacy paths and dry-run candidates"
            `Quick
            test_classifies_legacy_paths_and_dry_run_candidates
        ; Alcotest.test_case "scan cap marks truncation" `Quick test_scan_cap_marks_truncation
        ] )
    ]
