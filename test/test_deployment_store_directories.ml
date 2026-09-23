open Alcotest
open Masc

let read path = In_channel.with_open_bin path In_channel.input_all
let write path text = Out_channel.with_open_bin path (fun out -> output_string out text)

let invoke exe root =
  let stdout_path = Filename.concat root "stdout" in
  let stderr_path = Filename.concat root "stderr" in
  let output = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let errors = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let status = Fun.protect ~finally:(fun () -> Unix.close output; Unix.close errors) (fun () ->
    let pid = Unix.create_process exe
      [|exe; "validate-stores"; "--base-path"; root|] Unix.stdin output errors in
    snd (Unix.waitpid [] pid)) in
  status, read stdout_path ^ read stderr_path

let with_workspace f =
  let root = Filename.temp_dir "preflight-directories-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let keepers = Filename.concat root ".masc/keepers" in
    let traces = Filename.concat root ".masc/traces" in
    Fs_compat.mkdir_p (Filename.concat keepers "keeper");
    Fs_compat.mkdir_p (Filename.concat traces "trace");
    write (Filename.concat keepers "keeper.decisions.jsonl") "not a directory\n";
    write (Filename.concat traces "trace.checkpoint.lock") "lock metadata\n";
    f root keepers traces)

let test_regular_siblings exe () = with_workspace (fun root keepers traces ->
  let status, output = invoke exe root in
  check bool ("regular siblings must not become stores: " ^ output) true (status = Unix.WEXITED 0);
  check string "journal unchanged" "not a directory\n"
    (read (Filename.concat keepers "keeper.decisions.jsonl"));
  check string "lock unchanged" "lock metadata\n"
    (read (Filename.concat traces "trace.checkpoint.lock")))

let test_real_store_refusals exe () = with_workspace (fun root keepers traces ->
  let boundary = Filename.concat keepers "keeper/turn-boundaries.jsonl" in
  let fragment = Filename.concat traces "trace/history.jsonl" in
  write boundary "{invalid boundary}\n";
  write fragment "{invalid fragment}\n";
  let status, output = invoke exe root in
  check bool "malformed real stores still refuse deployment" true (status <> Unix.WEXITED 0);
  List.iter (fun expected ->
    check bool ("reports " ^ expected) true (String_util.contains_substring output expected))
    ["keeper turn boundaries rows=1 refused=1";
     "keeper official-client turn fragments rows=1 refused=1"];
  check string "refused boundary preserved" "{invalid boundary}\n" (read boundary);
  check string "refused fragment preserved" "{invalid fragment}\n" (read fragment))

(* Every Memory write for a keeper reconciles its range receipt ledger before
   it builds, so a ledger this build cannot decode must stop the rollout here,
   not every Memory write after it. *)
let test_range_receipt_ledger exe () = with_workspace (fun root _keepers _traces ->
  let config_keepers = Filename.concat root ".masc/config/keepers" in
  Fs_compat.mkdir_p config_keepers;
  let ledger = Filename.concat config_keepers "keeper.librarian-range-commit.json" in
  write ledger {|{"receipts":[]}|};
  let status, output = invoke exe root in
  check bool ("a readable ledger passes: " ^ output) true (status = Unix.WEXITED 0);
  check bool ("the readable ledger is read: " ^ output) true
    (String_util.contains_substring output "Librarian range receipt ledger rows=1 refused=0");
  write ledger {|{"receipts":{}}|};
  let status, output = invoke exe root in
  check bool "an undecodable ledger refuses deployment" true (status <> Unix.WEXITED 0);
  check bool ("reports the ledger: " ^ output) true
    (String_util.contains_substring output "Librarian range receipt ledger rows=1 refused=1");
  check string "refused ledger preserved" {|{"receipts":{}}|} (read ledger))

let test_symlink_refusal exe () = with_workspace (fun root keepers _traces ->
  Unix.symlink (Filename.concat keepers "keeper") (Filename.concat keepers "linked");
  let status, output = invoke exe root in
  check bool "links are not silently skipped or followed" true (status <> Unix.WEXITED 0);
  check bool "uninspectable store is explicit" true
    (String_util.contains_substring output "store entry cannot be inspected safely"))

(* On a cluster other than the default one the runtime writes keeper stores
   under [.masc/clusters/<cluster>/keepers]. The gate has to read that
   directory: reading [.masc/keepers] instead finds no rows there and lets a
   row the new binary refuses through. Written with the default cluster, the
   same rows are not in the directory the gate reads, so it reports zero. *)
let test_named_cluster_stores exe () = with_workspace (fun root _keepers _traces ->
  let write_refused_rows () =
    let keeper = Filename.concat (Workspace.keepers_runtime_dir_for_base_path root) "keeper" in
    List.iter (fun store ->
      let month = Filename.concat keeper (Filename.concat store "2026-09") in
      Fs_compat.mkdir_p month;
      write (Filename.concat month "rows.jsonl") "{\"unknown_field\":1}\n")
      ["turn-records"; "provider-inputs"]
  in
  let expected refused =
    ["keeper turn records " ^ refused; "keeper provider-input snapshots " ^ refused]
  in
  Masc_test_deps.with_process_env "MASC_CLUSTER_NAME" (Some "preflight-cluster") (fun () ->
    write_refused_rows ();
    let status, output = invoke exe root in
    check bool ("a named cluster's refused rows refuse deployment: " ^ output) true
      (status <> Unix.WEXITED 0);
    List.iter (fun line ->
      check bool ("reports " ^ line ^ ": " ^ output) true
        (String_util.contains_substring output line))
      (expected "rows=1 refused=1"));
  Masc_test_deps.with_process_env "MASC_CLUSTER_NAME" None (fun () ->
    let status, output = invoke exe root in
    check bool ("the default cluster does not read another cluster's rows: " ^ output) true
      (status = Unix.WEXITED 0);
    List.iter (fun line ->
      check bool ("reports " ^ line ^ ": " ^ output) true
        (String_util.contains_substring output line))
      (expected "rows=0 refused=0")))

let () =
  let exe = Sys.getenv "MASC_TEST_DEPLOYMENT_PREFLIGHT_EXE" in
  run "deployment store directories"
    ["live layout", [test_case "regular journals and locks are not stores" `Quick (test_regular_siblings exe);
      test_case "real decoder failures remain visible" `Quick (test_real_store_refusals exe);
      test_case "symlink remains a refusal" `Quick (test_symlink_refusal exe);
      test_case "range receipt ledger is read before rollout" `Quick
        (test_range_receipt_ledger exe);
      test_case "a named cluster's keeper stores are read" `Quick
        (test_named_cluster_stores exe)]]
