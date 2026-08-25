(** Tier I6 — Shared_audit unit tests.

    Verifies envelope hash determinism, JSON round-trip, and store-level
    chain integrity (append → recent → verify_chain → tampering detection). *)

open Alcotest

module Env = Shared_audit.Envelope
module Store = Shared_audit.Store

(* ──────────────────────────────────────────────────────────── *)
(* Helpers                                                       *)
(* ──────────────────────────────────────────────────────────── *)

let unique_temp_dir prefix =
  let base = Filename.get_temp_dir_name () in
  let suffix = Printf.sprintf "%s_%d_%d" prefix (Unix.getpid ()) (Random.bits ()) in
  let dir = Filename.concat base suffix in
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  try rm_rf dir with _ -> ()

let audit_path ~base_dir ~ts =
  let base_dir = Unix.realpath base_dir in
  let tm = Unix.gmtime ts in
  let yyyy_mm =
    Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
  in
  let dd = Printf.sprintf "%02d" tm.Unix.tm_mday in
  Filename.concat (Filename.concat base_dir yyyy_mm) (dd ^ ".jsonl")

let expect_corrupt_jsonl ~path f =
  match f () with
  | exception Store.Corrupt_jsonl { path = actual_path; line_number; detail } ->
    check string "corrupt audit path" path actual_path;
    check int "corrupt audit line" 2 line_number;
    check bool "corrupt audit detail is explicit" true (String.trim detail <> "")
  | _ -> fail "expected Store.Corrupt_jsonl"

(* ──────────────────────────────────────────────────────────── *)
(* Envelope                                                      *)
(* ──────────────────────────────────────────────────────────── *)

let test_envelope_make_basic () =
  let e = Env.make
    ~category:"TestCat"
    ~payload:(`Assoc [ "k", `Int 1 ])
    ~prev_hash:None
  in
  check string "category" "TestCat" e.category;
  check (option string) "no prev_hash" None e.prev_hash;
  check bool "id non-empty" true (String.length e.id > 0);
  check bool "ts > 0" true (e.ts > 0.0)

let test_envelope_ids_unique_across_domains () =
  let ids_per_domain = 256 in
  let domains =
    List.init 4 (fun _ ->
      Domain.spawn (fun () ->
        Array.init ids_per_domain (fun _ ->
          (Env.make ~category:"Concurrent" ~payload:`Null ~prev_hash:None).id)))
  in
  let ids =
    List.map Domain.join domains
    |> List.map Array.to_list
    |> List.concat
  in
  let unique = List.sort_uniq String.compare ids in
  check int "all domain-local random ids are unique" (4 * ids_per_domain)
    (List.length unique)

let test_envelope_canonical_json_deterministic () =
  let e = Env.make
    ~category:"X"
    ~payload:(`String "test")
    ~prev_hash:(Some "abc123")
  in
  let s1 = Env.canonical_json e in
  let s2 = Env.canonical_json e in
  check string "deterministic" s1 s2

let test_envelope_compute_hash_deterministic () =
  let e = Env.make
    ~category:"X"
    ~payload:(`Int 42)
    ~prev_hash:None
  in
  let h1 = Env.compute_hash e in
  let h2 = Env.compute_hash e in
  check string "hash deterministic" h1 h2;
  check int "SHA256 hex length" 64 (String.length h1)

let test_envelope_hash_changes_with_payload () =
  let e1 = { (Env.make ~category:"X" ~payload:(`Int 1) ~prev_hash:None)
             with ts = 1.0; id = "fixed-id" }
  in
  let e2 = { e1 with payload = `Int 2 } in
  check bool "different payload → different hash" true
    (Env.compute_hash e1 <> Env.compute_hash e2)

let test_envelope_json_round_trip () =
  let e = Env.make
    ~category:"RoundTrip"
    ~payload:(`Assoc [ "field", `String "value"; "n", `Int 7 ])
    ~prev_hash:(Some "deadbeef")
  in
  let json = Env.to_json e in
  match Env.of_json json with
  | Error msg -> fail msg
  | Ok back ->
    check string "id preserved" e.id back.id;
    check (float 1e-6) "ts preserved" e.ts back.ts;
    check string "category preserved" e.category back.category;
    check (option string) "prev_hash preserved" e.prev_hash back.prev_hash;
    check bool "payload equal"
      true (Yojson.Safe.equal e.payload back.payload)

let test_envelope_of_json_genesis_no_prev_hash_field () =
  let json = `Assoc [
    "id", `String "abc";
    "ts", `Float 1.0;
    "category", `String "X";
    "payload", `Null;
    (* no prev_hash field at all *)
  ] in
  match Env.of_json json with
  | Ok e -> check (option string) "missing prev_hash → None" None e.prev_hash
  | Error e -> fail e

let test_envelope_of_json_rejects_bad () =
  match Env.of_json (`Int 42) with
  | Ok _ -> fail "should reject non-object"
  | Error _ -> ()

(* ──────────────────────────────────────────────────────────── *)
(* Store: append + chain                                         *)
(* ──────────────────────────────────────────────────────────── *)

let test_store_append_chains () =
  let dir = unique_temp_dir "audit_chain" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let e1 = Store.append store ~category:"A" ~payload:(`Int 1) in
    let e2 = Store.append store ~category:"B" ~payload:(`Int 2) in
    let e3 = Store.append store ~category:"C" ~payload:(`Int 3) in
    check (option string) "first prev_hash None" None e1.prev_hash;
    check (option string) "second prev_hash = hash of first"
      (Some (Env.hash_for_chain e1)) e2.prev_hash;
    check (option string) "third prev_hash = hash of second"
      (Some (Env.hash_for_chain e2)) e3.prev_hash)

let test_store_recent_returns_n () =
  let dir = unique_temp_dir "audit_recent" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    for i = 1 to 5 do
      let _ = Store.append store ~category:"X" ~payload:(`Int i) in ()
    done;
    let last3 = Store.recent store ~n:3 in
    check int "3 entries" 3 (List.length last3);
    let payloads = List.map (fun (e : Env.t) ->
      match e.payload with `Int i -> i | _ -> -1) last3
    in
    check (list int) "last 3 are 3,4,5" [ 3; 4; 5 ] payloads)

let test_store_since_filters () =
  let dir = unique_temp_dir "audit_since" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let _ = Store.append store ~category:"X" ~payload:(`Int 1) in
    Unix.sleepf 0.05;
    let cutoff = Unix.gettimeofday () in
    Unix.sleepf 0.05;
    let _ = Store.append store ~category:"X" ~payload:(`Int 2) in
    let _ = Store.append store ~category:"X" ~payload:(`Int 3) in
    let after = Store.since store ~ts:cutoff in
    check int "2 entries after cutoff" 2 (List.length after))

let test_store_verify_chain_intact () =
  let dir = unique_temp_dir "audit_verify_intact" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    for i = 1 to 4 do
      let _ = Store.append store ~category:"V" ~payload:(`Int i) in ()
    done;
    let all = Store.recent store ~n:100 in
    match Store.verify_chain all with
    | Ok () -> ()
    | Error (idx, reason) ->
      fail (Printf.sprintf "chain broken at %d: %s" idx reason))

let test_store_verify_chain_detects_tampering () =
  let dir = unique_temp_dir "audit_verify_tamper" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let _ = Store.append store ~category:"X" ~payload:(`Int 1) in
    let _ = Store.append store ~category:"X" ~payload:(`Int 2) in
    let _ = Store.append store ~category:"X" ~payload:(`Int 3) in
    let all = Store.recent store ~n:100 in
    (* Tamper: replace middle entry's payload, keep its prev_hash *)
    let tampered = List.mapi (fun i (e : Env.t) ->
      if i = 1 then { e with payload = `Int 999 } else e) all
    in
    match Store.verify_chain tampered with
    | Ok () -> fail "should detect tampering"
    | Error (idx, _) ->
      (* The mismatch surfaces at the entry AFTER the tampered one,
         because its prev_hash no longer matches. *)
      check bool "broken link reported" true (idx >= 2))

let test_store_verify_empty_log () =
  let dir = unique_temp_dir "audit_verify_empty" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let report = Store.verify store in
    check int "no entries checked" 0 report.entries_checked;
    check bool "no failure on empty log" true (report.failure = None))

let test_store_verify_reports_intact_chain () =
  let dir = unique_temp_dir "audit_verify_report_ok" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    for i = 1 to 4 do
      let _ = Store.append store ~category:"V" ~payload:(`Int i) in ()
    done;
    let report = Store.verify store in
    check int "all entries checked" 4 report.entries_checked;
    check bool "no failure" true (report.failure = None))

let test_store_verify_reports_on_disk_tampering () =
  let dir = unique_temp_dir "audit_verify_report_broken" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let _ = Store.append store ~category:"X" ~payload:(`Int 1) in
    let e2 = Store.append store ~category:"X" ~payload:(`Int 2) in
    (* Forge a third line whose prev_hash does not chain to e2. The line
       lands in the same day-file as e2 so it is read after it. *)
    let forged =
      Env.make ~category:"X" ~payload:(`Int 3)
        ~prev_hash:(Some (String.make 64 '0'))
    in
    let path = audit_path ~base_dir:dir ~ts:e2.ts in
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 path in
    output_string oc (Yojson.Safe.to_string (Env.to_json forged));
    output_char oc '\n';
    close_out oc;
    let report = Store.verify store in
    check int "two links checked before break" 2 report.entries_checked;
    match report.failure with
    | Some (idx, reason) ->
      check int "break at forged index" 2 idx;
      check bool "reason non-empty" true (String.trim reason <> "")
    | None -> fail "expected broken chain report")

let test_store_resume_continues_chain () =
  let dir = unique_temp_dir "audit_resume" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store_a = Store.create ~base_dir:dir in
    let e1 = Store.append store_a ~category:"X" ~payload:(`Int 1) in
    (* "Restart": create a fresh store at the same dir. *)
    let store_b = Store.create ~base_dir:dir in
    let e2 = Store.append store_b ~category:"X" ~payload:(`Int 2) in
    check (option string)
      "resumed chain: e2.prev_hash = hash of e1"
      (Some (Env.hash_for_chain e1)) e2.prev_hash)

let test_store_instances_share_append_cursor () =
  let dir = unique_temp_dir "audit_shared_cursor" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    (* Create both handles before either append. Independent cached cursors
       would therefore both start at [None] and deterministically fork. *)
    let store_a = Store.create ~base_dir:dir in
    let store_b = Store.create ~base_dir:dir in
    let e1 = Store.append store_a ~category:"A" ~payload:(`Int 1) in
    let e2 = Store.append store_b ~category:"B" ~payload:(`Int 2) in
    let e3 = Store.append store_a ~category:"A" ~payload:(`Int 3) in
    check (option string)
      "B observes A's cursor"
      (Some (Env.hash_for_chain e1))
      e2.prev_hash;
    check (option string)
      "A observes B's cursor"
      (Some (Env.hash_for_chain e2))
      e3.prev_hash;
    match Store.verify_chain [ e1; e2; e3 ] with
    | Ok () -> ()
    | Error (idx, reason) ->
      fail (Printf.sprintf "shared-store chain broken at %d: %s" idx reason))

let test_store_resume_skips_empty_newer_partition () =
  let dir = unique_temp_dir "audit_empty_newer_partition" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let month_dir = Filename.concat dir "2020-01" in
    Unix.mkdir month_dir 0o755;
    let first =
      { (Env.make ~category:"X" ~payload:(`Int 1) ~prev_hash:None) with
        ts = 1_577_836_800.0 }
    in
    let first_path = Filename.concat month_dir "01.jsonl" in
    let oc = open_out first_path in
    output_string oc (Yojson.Safe.to_string (Env.to_json first));
    output_char oc '\n';
    close_out oc;
    let empty_path = Filename.concat month_dir "02.jsonl" in
    close_out (open_out empty_path);
    let store = Store.create ~base_dir:dir in
    let next = Store.append store ~category:"X" ~payload:(`Int 2) in
    check (option string)
      "empty newer day does not reset cursor"
      (Some (Env.hash_for_chain first))
      next.prev_hash)

let test_store_resume_scans_only_latest_non_empty_partition () =
  let dir = unique_temp_dir "audit_latest_partition_only" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let old_month_dir = Filename.concat dir "2019-01" in
    let latest_month_dir = Filename.concat dir "2020-01" in
    Unix.mkdir old_month_dir 0o755;
    Unix.mkdir latest_month_dir 0o755;
    let old_path = Filename.concat old_month_dir "01.jsonl" in
    let old_channel = open_out old_path in
    output_string old_channel "{historical entry need not be materialized\n";
    close_out old_channel;
    let latest =
      { (Env.make ~category:"X" ~payload:(`Int 1) ~prev_hash:None) with
        ts = 1_577_836_800.0 }
    in
    let latest_path = Filename.concat latest_month_dir "01.jsonl" in
    let latest_channel = open_out latest_path in
    output_string latest_channel (Yojson.Safe.to_string (Env.to_json latest));
    output_char latest_channel '\n';
    close_out latest_channel;
    let store = Store.create ~base_dir:dir in
    let next = Store.append store ~category:"X" ~payload:(`Int 2) in
    check (option string)
      "cursor comes from latest non-empty partition"
      (Some (Env.hash_for_chain latest))
      next.prev_hash)

let test_store_alias_keeps_canonical_io_target () =
  let root = unique_temp_dir "audit_canonical_io" in
  let actual = Filename.concat root "actual" in
  let redirected = Filename.concat root "redirected" in
  let alias = Filename.concat root "alias" in
  Unix.mkdir actual 0o755;
  Unix.mkdir redirected 0o755;
  Unix.symlink actual alias;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove alias with Sys_error _ -> ());
      cleanup_dir root)
    (fun () ->
      let store = Store.create ~base_dir:alias in
      Sys.remove alias;
      Unix.symlink redirected alias;
      ignore (Store.append store ~category:"X" ~payload:(`Int 1));
      let canonical_store = Store.create ~base_dir:actual in
      check int "entry stayed in canonical directory" 1
        (List.length (Store.recent canonical_store ~n:10));
      check int "retargeted alias received no files" 0
        (Array.length (Sys.readdir redirected)))

let test_store_rejects_replaced_canonical_directory () =
  let root = unique_temp_dir "audit_replaced_directory" in
  let active = Filename.concat root "audit" in
  let rotated = Filename.concat root "audit.rotated" in
  Unix.mkdir active 0o755;
  Fun.protect ~finally:(fun () -> cleanup_dir root) (fun () ->
    let old_store = Store.create ~base_dir:active in
    ignore (Store.append old_store ~category:"old" ~payload:(`Int 1));
    Unix.rename active rotated;
    Unix.mkdir active 0o755;
    let replacement_store = Store.create ~base_dir:active in
    let replacement_entry =
      Store.append replacement_store ~category:"new" ~payload:(`Int 1)
    in
    check (option string) "replacement starts its own chain" None
      replacement_entry.prev_hash;
    let rotated_store = Store.create ~base_dir:rotated in
    check int "replacement append did not reuse rotated cached writer" 1
      (List.length (Store.recent rotated_store ~n:10));
    check int "replacement append reached replacement directory" 1
      (List.length (Store.recent replacement_store ~n:10));
    match Store.append old_store ~category:"old" ~payload:(`Int 2) with
    | exception
        Store.Base_directory_replaced
          { path
          ; expected_device_id
          ; expected_inode_id
          ; actual_device_id
          ; actual_inode_id
          } ->
      check string "reports canonical path" (Unix.realpath active) path;
      check bool "device or inode changed" true
        (actual_device_id <> Some expected_device_id
         || actual_inode_id <> Some expected_inode_id);
      check int "old handle did not write into replacement" 1
        (List.length (Store.recent replacement_store ~n:10))
    | _ -> fail "expected Store.Base_directory_replaced")

let test_store_rejects_malformed_jsonl_lines () =
  let dir = unique_temp_dir "audit_malformed" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let valid = Store.append store ~category:"X" ~payload:(`Int 1) in
    let path = audit_path ~base_dir:dir ~ts:valid.ts in
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 path in
    output_string oc "{not json\n";
    close_out oc;
    expect_corrupt_jsonl ~path (fun () -> ignore (Store.recent store ~n:10)))

let test_store_rejects_invalid_envelope_jsonl_lines () =
  let dir = unique_temp_dir "audit_invalid_envelope" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let valid = Store.append store ~category:"X" ~payload:(`Int 1) in
    let path = audit_path ~base_dir:dir ~ts:valid.ts in
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 path in
    output_string oc
      {|{"id":"bad-envelope","ts":1.0,"payload":{"kind":"missing-category"}}|};
    output_char oc '\n';
    close_out oc;
    expect_corrupt_jsonl ~path (fun () -> ignore (Store.recent store ~n:10)))

let test_store_resume_rejects_malformed_jsonl_lines () =
  let dir = unique_temp_dir "audit_malformed_resume" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    let valid = Store.append store ~category:"X" ~payload:(`Int 1) in
    let path = audit_path ~base_dir:dir ~ts:valid.ts in
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 path in
    output_string oc "{not json\n";
    close_out oc;
    expect_corrupt_jsonl ~path (fun () -> ignore (Store.create ~base_dir:dir)))

let test_store_base_dir_inspector () =
  let dir = unique_temp_dir "audit_inspector" in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () ->
    let store = Store.create ~base_dir:dir in
    check string "canonical base_dir reported" (Unix.realpath dir) (Store.base_dir store))

(* ──────────────────────────────────────────────────────────── *)
(* Suite                                                         *)
(* ──────────────────────────────────────────────────────────── *)

let () =
  Random.self_init ();
  run "Shared_audit" [
    "Envelope", [
      test_case "make basic" `Quick test_envelope_make_basic;
      test_case "ids unique across domains" `Quick
        test_envelope_ids_unique_across_domains;
      test_case "canonical_json deterministic" `Quick test_envelope_canonical_json_deterministic;
      test_case "compute_hash deterministic" `Quick test_envelope_compute_hash_deterministic;
      test_case "hash changes with payload" `Quick test_envelope_hash_changes_with_payload;
      test_case "json round-trip" `Quick test_envelope_json_round_trip;
      test_case "missing prev_hash field accepted" `Quick test_envelope_of_json_genesis_no_prev_hash_field;
      test_case "rejects non-object" `Quick test_envelope_of_json_rejects_bad;
    ];
    "Store", [
      test_case "append chains prev_hash" `Quick test_store_append_chains;
      test_case "recent returns N" `Quick test_store_recent_returns_n;
      test_case "since filters by timestamp" `Quick test_store_since_filters;
      test_case "verify_chain intact" `Quick test_store_verify_chain_intact;
      test_case "verify_chain detects tampering" `Quick test_store_verify_chain_detects_tampering;
      test_case "verify empty log" `Quick test_store_verify_empty_log;
      test_case "verify reports intact chain" `Quick test_store_verify_reports_intact_chain;
      test_case "verify reports on-disk tampering" `Quick test_store_verify_reports_on_disk_tampering;
      test_case "resume continues chain" `Quick test_store_resume_continues_chain;
      test_case "instances share append cursor" `Quick test_store_instances_share_append_cursor;
      test_case "resume skips empty newer partition" `Quick
        test_store_resume_skips_empty_newer_partition;
      test_case "resume scans only latest non-empty partition" `Quick
        test_store_resume_scans_only_latest_non_empty_partition;
      test_case "alias keeps canonical I/O target" `Quick
        test_store_alias_keeps_canonical_io_target;
      test_case "rejects replaced canonical directory" `Quick
        test_store_rejects_replaced_canonical_directory;
      test_case "rejects malformed JSONL lines" `Quick test_store_rejects_malformed_jsonl_lines;
      test_case "rejects invalid envelope JSONL lines" `Quick test_store_rejects_invalid_envelope_jsonl_lines;
      test_case "resume rejects malformed JSONL lines" `Quick test_store_resume_rejects_malformed_jsonl_lines;
      test_case "base_dir inspector" `Quick test_store_base_dir_inspector;
    ];
  ]
