(** Regression tests for legacy [.masc/keepers] inventory. *)

module Inventory = Server_dashboard_http_legacy_keeper_inventory

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    (try Unix.rmdir path with
     | Unix.Unix_error _ -> ())
  | _ ->
    (try Unix.unlink path with
     | Unix.Unix_error _ -> ())
;;

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

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

let string_field name json =
  match assoc_field name json with
  | Some (`String s) -> s
  | _ -> Alcotest.failf "expected string field %S" name
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
  with_temp_dir "masc-legacy-keeper-inventory" @@ fun base ->
  let legacy = Filename.concat (Filename.concat base ".masc") "keepers" in
  let current = Config_dir_resolver.keepers_dir_for_base_path ~base_path:base in
  ensure_dir (Filename.concat base ".masc");
  ensure_dir legacy;
  ensure_dir (Filename.dirname current);
  ensure_dir current;
  ensure_dir (Filename.concat legacy "alpha");
  ensure_dir (Filename.concat legacy "alpha/metrics");
  write_file (Filename.concat legacy "alpha.json") "{}\n";
  write_file (Filename.concat legacy "alpha/.atomic_dead.tmp") "orphan";
  write_file (Filename.concat legacy "PYEOF") "marker";
  write_file (Filename.concat legacy "alpha/old.backup") "backup";
  write_file (Filename.concat legacy "alpha/facts.jsonl") "{}\n";
  write_file (Filename.concat current "alpha.facts.jsonl") "{}\n";
  write_file (Filename.concat legacy "alpha/metrics/2026.jsonl") "{}\n";
  write_file (Filename.concat legacy "alpha/metrics/data.tmp") "runtime scratch";
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
  Alcotest.(check bool) "scan complete" true (bool_field "scan_complete" json);
  Alcotest.(check string)
    "path scope"
    "workspace_relative"
    (string_field "path_scope" json);
  Alcotest.(check string)
    "legacy path redacted"
    ".masc/keepers"
    (string_field "legacy_keepers_path" json);
  Alcotest.(check string)
    "config keepers path redacted"
    ".masc/config/keepers"
    (string_field "current_config_keepers_path" json);
  Alcotest.(check int) "orphaned count" 0 (class_count "orphaned" json);
  Alcotest.(check int) "backup count" 0 (class_count "backup" json);
  Alcotest.(check int) "migrated count" 1 (class_count "migrated" json);
  Alcotest.(check bool)
    "keeper meta json classified"
    true
    (List.mem ("alpha.json", "live") (entry_classes json));
  Alcotest.(check bool)
    "live metric classified"
    true
    (List.mem ("alpha/metrics/2026.jsonl", "live") (entry_classes json));
  Alcotest.(check bool)
    "tmp under runtime store stays live"
    true
    (List.mem ("alpha/metrics/data.tmp", "live") (entry_classes json));
  Alcotest.(check bool)
    "unknown file classified"
    true
    (List.mem ("mystery.bin", "unknown") (entry_classes json));
  Alcotest.(check bool)
    "temp file requires owner proof"
    true
    (List.mem ("alpha/.atomic_dead.tmp", "unknown") (entry_classes json));
  Alcotest.(check bool)
    "marker file requires owner proof"
    true
    (List.mem ("PYEOF", "unknown") (entry_classes json));
  Alcotest.(check bool)
    "backup file requires owner proof"
    true
    (List.mem ("alpha/old.backup", "unknown") (entry_classes json));
  let plan = object_field "dry_run_cleanup_plan" json in
  Alcotest.(check bool) "delete disabled" false (bool_field "delete_allowed" plan);
  Alcotest.(check bool)
    "operator approval required"
    true
    (bool_field "requires_operator_approval" plan);
  Alcotest.(check string)
    "candidate policy"
    "not_available_until_owner_verified"
    (string_field "candidate_policy" plan);
  Alcotest.(check string)
    "candidate source"
    "inventory_only"
    (string_field "candidate_source" plan)
;;

let test_scan_cap_marks_truncation () =
  with_temp_dir "masc-legacy-keeper-inventory-cap" @@ fun base ->
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

let test_reports_scan_errors_for_invalid_legacy_root () =
  with_temp_dir "masc-legacy-keeper-inventory-error" @@ fun base ->
  let masc = Filename.concat base ".masc" in
  ensure_dir masc;
  write_file (Filename.concat masc "keepers") "not a directory";
  let json =
    Inventory.legacy_keeper_inventory_http_json
      ~base_path:base
      ~max_depth:4
      ~max_entries:100
      ()
  in
  Alcotest.(check bool) "legacy root exists" true (bool_field "exists" json);
  Alcotest.(check bool) "scan incomplete" false (bool_field "scan_complete" json);
  let errors = list_field "scan_errors" json in
  Alcotest.(check int) "scan error count" 1 (List.length errors);
  (match List.hd errors with
   | `Assoc fields ->
     Alcotest.(check (option string))
       "error path"
       (Some ".")
       (match List.assoc_opt "path" fields with
        | Some (`String path) -> Some path
        | _ -> None);
     Alcotest.(check (option string))
       "error operation"
       (Some "readdir")
       (match List.assoc_opt "operation" fields with
        | Some (`String operation) -> Some operation
        | _ -> None)
   | _ -> Alcotest.fail "scan error must be an object")
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
        ; Alcotest.test_case
            "reports scan errors"
            `Quick
            test_reports_scan_errors_for_invalid_legacy_root
        ] )
    ]
