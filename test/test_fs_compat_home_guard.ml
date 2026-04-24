(* #9921: write-boundary guard complementing the #9903 path-resolution
   guard.  If any code path bypasses [Env_config_core.base_path()] and
   asks [Fs_compat] to write under HOME, the guard raises
   [Fs_compat.Test_isolation_breach] so the test crashes loud instead
   of silently corrupting the production ledger.  The real production
   ledger was observed to hold 106 test-pattern voter rows
   ([hot-voter-*], [flipper], [same-voter], [judge]) written before the
   #9920 partial fix landed. *)

module FC = Fs_compat

let home () =
  match Sys.getenv_opt "HOME" with
  | Some h when h <> "" -> h
  | _ -> Alcotest.fail "HOME unset — cannot exercise guard"

let disable_escape_hatch () =
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" ""

let test_append_under_home_raises () =
  disable_escape_hatch ();
  let path = Filename.concat (home ()) ".masc/_9921_guard_probe.jsonl" in
  try
    FC.append_file path "{\"probe\":1}\n";
    Alcotest.failf "expected Test_isolation_breach, but write succeeded to %S" path
  with FC.Test_isolation_breach msg ->
    Alcotest.(check bool)
      "message references #9921"
      true
      (let m = String.lowercase_ascii msg in
       let needle = "#9921" in
       let nlen = String.length needle in
       let rec scan i =
         if i + nlen > String.length m then false
         else if String.sub m i nlen = needle then true
         else scan (i + 1)
       in scan 0)

let test_save_under_home_raises () =
  disable_escape_hatch ();
  let path = Filename.concat (home ()) ".masc/_9921_guard_probe_save.txt" in
  try
    FC.save_file path "probe";
    Alcotest.fail "expected Test_isolation_breach on save_file"
  with FC.Test_isolation_breach _ -> ()

let test_mkdir_under_home_raises () =
  disable_escape_hatch ();
  let path = Filename.concat (home ()) ".masc/_9921_guard_probe_dir" in
  try
    FC.mkdir_p path;
    Alcotest.fail "expected Test_isolation_breach on mkdir_p"
  with FC.Test_isolation_breach _ -> ()

let test_tmp_write_allowed () =
  disable_escape_hatch ();
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-9921-guard-allow-%d" (Unix.getpid ()))
  in
  FC.mkdir_p dir;
  let path = Filename.concat dir "probe.txt" in
  FC.append_file path "ok\n";
  Alcotest.(check bool) "tmp write succeeded" true (Sys.file_exists path);
  (* clean up *)
  (try Sys.remove path with Sys_error _ -> ());
  (try Unix.rmdir dir with Unix.Unix_error _ -> ())

let test_escape_hatch_allows_home () =
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "1";
  let path = Filename.concat (home ()) ".masc/_9921_guard_probe_bypass.jsonl" in
  (try
    FC.append_file path "{\"bypass\":1}\n";
    Alcotest.(check bool) "bypass write succeeded" true (Sys.file_exists path)
  with FC.Test_isolation_breach msg ->
    Alcotest.failf
      "escape hatch should allow HOME write, got Test_isolation_breach: %s" msg);
  (* clean up so we do not leave probe junk in the real ledger dir *)
  (try Sys.remove path with Sys_error _ -> ());
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" ""

let () =
  Alcotest.run "fs_compat_home_guard" [
    "guard", [
      Alcotest.test_case "append under HOME raises" `Quick
        test_append_under_home_raises;
      Alcotest.test_case "save under HOME raises" `Quick
        test_save_under_home_raises;
      Alcotest.test_case "mkdir under HOME raises" `Quick
        test_mkdir_under_home_raises;
      Alcotest.test_case "tmp write allowed" `Quick
        test_tmp_write_allowed;
      Alcotest.test_case "escape hatch allows HOME" `Quick
        test_escape_hatch_allows_home;
    ];
  ]
