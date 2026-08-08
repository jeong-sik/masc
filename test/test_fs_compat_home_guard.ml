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

let guard_path name =
  Filename.concat (home ()) (Filename.concat "masc-home-guard" name)

let test_append_under_home_raises () =
  disable_escape_hatch ();
  let path = guard_path "_9921_guard_probe.jsonl" in
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
  let path = guard_path "_9921_guard_probe_save.txt" in
  try
    FC.save_file path "probe";
    Alcotest.fail "expected Test_isolation_breach on save_file"
  with FC.Test_isolation_breach _ -> ()

let test_mkdir_under_home_raises () =
  disable_escape_hatch ();
  let path = guard_path "_9921_guard_probe_dir" in
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

(* --- #27596: containment is decided by destination, not by spelling. --- *)

let with_home new_home f =
  let real = home () in
  Fun.protect
    ~finally:(fun () -> Unix.putenv "HOME" real)
    (fun () ->
      Unix.putenv "HOME" new_home;
      f ())

let fresh_base label =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-27596-%s-%d" label (Unix.getpid ()))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let expect_blocked what f =
  try
    f ();
    Alcotest.failf "expected Test_isolation_breach: %s" what
  with FC.Test_isolation_breach _ -> ()

let expect_allowed what f =
  try f () with
  | FC.Test_isolation_breach msg -> Alcotest.failf "%s: %s" what msg

(* A path that lands under HOME while spelled so a prefix comparison misses it.
   [<base>/other/../home/x] never shares HOME's prefix as a string. *)
let test_dotdot_reentry_is_blocked () =
  disable_escape_hatch ();
  let base = fresh_base "dotdot" in
  let fake_home = Filename.concat base "home" in
  (try Unix.mkdir fake_home 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let other = Filename.concat base "other" in
  (try Unix.mkdir other 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  with_home fake_home (fun () ->
    expect_blocked "<base>/other/../home/probe re-enters HOME" (fun () ->
      FC.append_file (Filename.concat other "../home/probe.jsonl") "x\n"));
  expect_blocked "duplicate separators still land under HOME" (fun () ->
    with_home fake_home (fun () ->
      FC.append_file (fake_home ^ "//probe2.jsonl") "x\n"))

(* A symlink outside HOME whose target is inside it. The destination is what
   matters; the spelling shares nothing with HOME. *)
let test_symlink_into_home_is_blocked () =
  disable_escape_hatch ();
  let base = fresh_base "symlink" in
  let fake_home = Filename.concat base "home" in
  (try Unix.mkdir fake_home 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let link = Filename.concat base "link" in
  (try Unix.symlink fake_home link with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  with_home fake_home (fun () ->
    expect_blocked "<base>/link -> HOME" (fun () ->
      FC.append_file (Filename.concat link "probe.jsonl") "x\n"))

(* HOME=/ with a relative path: it resolves under the cwd, which is under /. *)
let test_home_root_blocks_relative_path () =
  disable_escape_hatch ();
  with_home "/" (fun () ->
    expect_blocked "relative path under HOME=/" (fun () ->
      FC.append_file "masc-27596-relative-probe.jsonl" "x\n"))

(* A sibling whose name merely extends HOME's is not under HOME. *)
let test_sibling_allowed () =
  disable_escape_hatch ();
  let base = fresh_base "sibling" in
  let fake_home = Filename.concat base "home" in
  (try Unix.mkdir fake_home 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sibling = fake_home ^ "-cache" in
  with_home fake_home (fun () ->
    expect_allowed "sibling of HOME" (fun () ->
      FC.mkdir_p sibling;
      FC.append_file (Filename.concat sibling "probe.txt") "ok\n"))

(* HOME=/ makes every absolute path contained. Appending a separator to the
   root would look for "//" and block nothing. *)
let test_home_root_blocks_absolute_path () =
  disable_escape_hatch ();
  let path =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-27596-abs-%d.txt" (Unix.getpid ()))
  in
  with_home "/" (fun () ->
    expect_blocked "absolute path under HOME=/" (fun () ->
      FC.append_file path "x\n"))

(* HOME itself, not just what is under it. *)
let test_home_itself_is_blocked () =
  disable_escape_hatch ();
  let base = fresh_base "exact" in
  let fake_home = Filename.concat base "home" in
  (try Unix.mkdir fake_home 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  with_home fake_home (fun () ->
    expect_blocked "HOME itself" (fun () -> FC.mkdir_p fake_home))

(* The second entrypoint has to answer the same way. *)
let test_base_path_guard_agrees () =
  disable_escape_hatch ();
  let base = fresh_base "cfgguard" in
  let fake_home = Filename.concat base "home" in
  (try Unix.mkdir fake_home 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let sibling = fake_home ^ "-cache" in
  with_home fake_home (fun () ->
    (match Env_config_core.base_path_prod_guard sibling with
     | _ -> ()
     | exception Env_config_core.Config_error msg ->
       Alcotest.failf "sibling %S rejected by base_path guard: %s" sibling msg);
    let inside = Filename.concat fake_home "ledger" in
    match Env_config_core.base_path_prod_guard inside with
    | value ->
      Alcotest.failf "expected Config_error for %S, got %S" inside value
    | exception Env_config_core.Config_error _ -> ())

let test_escape_hatch_allows_home () =
  Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "1";
  let path = guard_path "_9921_guard_probe_bypass.jsonl" in
  let parent = Filename.dirname path in
  let parent_existed = Sys.file_exists parent in
  Fun.protect
    ~finally:(fun () ->
      (* clean up so we do not leave probe junk in the real ledger dir *)
      (try Sys.remove path with Sys_error _ -> ());
      (if not parent_existed then
         try Unix.rmdir parent with Unix.Unix_error _ -> ());
      Unix.putenv "MASC_TEST_ALLOW_HOME_BASE_PATH" "")
    (fun () ->
      FC.mkdir_p parent;
      try
        FC.append_file path "{\"bypass\":1}\n";
        Alcotest.(check bool) "bypass write succeeded" true (Sys.file_exists path)
      with FC.Test_isolation_breach msg ->
        Alcotest.failf
          "escape hatch should allow HOME write, got Test_isolation_breach: %s" msg)

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
      Alcotest.test_case "sibling of HOME allowed" `Quick
        test_sibling_allowed;
      Alcotest.test_case "HOME=/ blocks absolute path" `Quick
        test_home_root_blocks_absolute_path;
      Alcotest.test_case "HOME itself blocked" `Quick
        test_home_itself_is_blocked;
      Alcotest.test_case "dotdot re-entry blocked" `Quick
        test_dotdot_reentry_is_blocked;
      Alcotest.test_case "symlink into HOME blocked" `Quick
        test_symlink_into_home_is_blocked;
      Alcotest.test_case "HOME=/ blocks relative path" `Quick
        test_home_root_blocks_relative_path;
      Alcotest.test_case "base_path guard agrees" `Quick
        test_base_path_guard_agrees;
      Alcotest.test_case "escape hatch allows HOME" `Quick
        test_escape_hatch_allows_home;
    ];
  ]
