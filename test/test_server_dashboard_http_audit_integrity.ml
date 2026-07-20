(** Regression tests for the audit-integrity dashboard helper. *)

module Integrity = Server_dashboard_http_audit_integrity
module Env = Shared_audit.Envelope
module Store = Shared_audit.Store

(* [Filename.temp_dir] creates the directory atomically. *)
let fresh_dir prefix = Filename.temp_dir prefix ""

let audit_path ~base_dir ~ts =
  let tm = Unix.gmtime ts in
  let yyyy_mm =
    Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
  in
  let dd = Printf.sprintf "%02d" tm.Unix.tm_mday in
  Filename.concat (Filename.concat base_dir yyyy_mm) (dd ^ ".jsonl")
;;

let keeper_dir ~base keeper_id =
  Filename.concat
    (Filename.concat (Filename.concat base ".masc") "resilience_audit")
    keeper_id
;;

let append_entries ~base keeper_id payloads =
  let store = Store.create ~base_dir:(keeper_dir ~base keeper_id) in
  List.map (fun i -> Store.append store ~category:"Test" ~payload:(`Int i)) payloads
;;

(* Append a forged line whose prev_hash does not chain to the latest entry,
   landing in the same day-file so it is read after it. *)
let forge_line ~base keeper_id ~after =
  let forged =
    Env.make ~category:"Test" ~payload:(`Int 999)
      ~prev_hash:(Some (String.make 64 '0'))
  in
  let path = audit_path ~base_dir:(keeper_dir ~base keeper_id) ~ts:after.Env.ts in
  let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 path in
  output_string oc (Yojson.Safe.to_string (Env.to_json forged));
  output_char oc '\n';
  close_out oc
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

let list_field name json =
  match assoc_field name json with
  | Some (`List xs) -> xs
  | _ -> Alcotest.failf "expected list field %S" name
;;

let keeper_ids json =
  list_field "keepers" json
  |> List.filter_map (fun k ->
    match assoc_field "keeper_id" k with
    | Some (`String s) -> Some s
    | _ -> None)
;;

let keeper_obj id json =
  match
    List.find_opt
      (fun k ->
        match assoc_field "keeper_id" k with
        | Some (`String s) -> String.equal s id
        | _ -> false)
      (list_field "keepers" json)
  with
  | Some k -> k
  | None -> Alcotest.failf "keeper %S not present in snapshot" id
;;

let totals json =
  match assoc_field "totals" json with
  | Some t -> t
  | None -> Alcotest.fail "expected totals object"
;;

let test_missing_audit_root_yields_empty_snapshot () =
  let base = fresh_dir "masc-audit-integrity-empty" in
  let json = Integrity.audit_integrity_http_json ~base_path:base in
  Alcotest.(check (list string)) "no keepers" [] (keeper_ids json);
  Alcotest.(check int) "totals.keepers 0" 0 (int_field "keepers" (totals json));
  Alcotest.(check int) "totals.entries 0" 0 (int_field "entries" (totals json));
  Alcotest.(check int) "totals.failed 0" 0 (int_field "failed" (totals json));
  Alcotest.(check bool)
    "resilience_enabled is a bool"
    true
    (match assoc_field "resilience_enabled" json with
     | Some (`Bool _) -> true
     | _ -> false)
;;

let test_reports_intact_chain () =
  let base = fresh_dir "masc-audit-integrity-ok" in
  ignore (append_entries ~base "solo" [ 1; 2; 3 ]);
  let json = Integrity.audit_integrity_http_json ~base_path:base in
  let k = keeper_obj "solo" json in
  Alcotest.(check bool) "chain ok" true (bool_field "ok" k);
  Alcotest.(check int) "entries counted" 3 (int_field "entries" k);
  Alcotest.(check bool)
    "broken_at null"
    true
    (match assoc_field "broken_at" k with
     | Some `Null -> true
     | _ -> false);
  Alcotest.(check int) "totals.ok 1" 1 (int_field "ok" (totals json));
  Alcotest.(check int) "totals.failed 0" 0 (int_field "failed" (totals json));
  Alcotest.(check int) "totals.entries 3" 3 (int_field "entries" (totals json))
;;

let test_reports_broken_chain_and_sorts_failures_first () =
  let base = fresh_dir "masc-audit-integrity-broken" in
  ignore (append_entries ~base "healthy" [ 1; 2 ]);
  let appended = append_entries ~base "tampered" [ 1; 2 ] in
  (match List.rev appended with
   | last :: _ -> forge_line ~base "tampered" ~after:last
   | [] -> Alcotest.fail "expected appended entries");
  let json = Integrity.audit_integrity_http_json ~base_path:base in
  let k = keeper_obj "tampered" json in
  Alcotest.(check bool) "chain not ok" false (bool_field "ok" k);
  Alcotest.(check int) "entries before break" 2 (int_field "entries" k);
  Alcotest.(check bool)
    "broken_at = forged index 2"
    true
    (match assoc_field "broken_at" k with
     | Some (`Int 2) -> true
     | _ -> false);
  Alcotest.(check bool)
    "detail present"
    true
    (match assoc_field "detail" k with
     | Some (`String s) -> String.trim s <> ""
     | _ -> false);
  Alcotest.(check (list string))
    "failed keeper sorts first"
    [ "tampered"; "healthy" ]
    (keeper_ids json);
  Alcotest.(check int) "totals.failed 1" 1 (int_field "failed" (totals json));
  Alcotest.(check int) "totals.ok 1" 1 (int_field "ok" (totals json))
;;

let () =
  Alcotest.run
    "server_dashboard_http_audit_integrity"
    [ ( "snapshot"
      , [ Alcotest.test_case
            "missing audit root yields empty snapshot"
            `Quick
            test_missing_audit_root_yields_empty_snapshot
        ; Alcotest.test_case
            "reports intact chain"
            `Quick
            test_reports_intact_chain
        ; Alcotest.test_case
            "reports broken chain and sorts failures first"
            `Quick
            test_reports_broken_chain_and_sorts_failures_first
        ] )
    ]
