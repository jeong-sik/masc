open Alcotest
module S = Runtime_setup_login_session
let get = function Ok value -> value | Error e -> fail (S.error_message e)
let temporary f =
  let path = Filename.temp_dir "masc-login-session-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
let with_session path f = S.with_session ~workspace:path ~actor:"operator" ~account_key:path f |> get
let isolated_scope () = temporary (fun path ->
  with_session path (fun session ->
    check bool "owner can see live session" true (S.is_active ~workspace:path ~actor:"operator" ~login_id:(S.id session));
    check bool "other actor refused" true (S.cancel ~workspace:path ~actor:"other" ~login_id:(S.id session) = Error S.Not_found);
    temporary (fun other -> check bool "other workspace refused" true
      (S.cancel ~workspace:other ~actor:"operator" ~login_id:(S.id session) = Error S.Not_found));
    check bool "duplicate store refused" true
      (S.with_session ~workspace:path ~actor:"another" ~account_key:path (fun _ -> Ok ()) = Error S.Already_running);
    let occupied = S.with_session ~workspace:path ~actor:"operator" ~account_key:"new-provisional" (fun other ->
      check bool "new reference cannot race the live store" true (S.bind_account other ~account_key:path = Error S.Already_running); Ok ()) in
    get occupied; Ok ()))
let run_process scenario = Eio_main.run (fun env -> temporary (fun path ->
  let env = (env :> Eio_unix.Stdenv.base) in
  let clock = Eio.Stdenv.clock env in
  match Eio.Time.with_timeout clock 10. (fun () -> Ok (with_session path (fun session -> scenario env path session))) with
  | Ok () -> () | Error `Timeout -> fail "login process lifetime did not terminate"))
let normal_exit () = run_process (fun env path session ->
  let output = Buffer.create 16 in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"print('ready')"] ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> ()) ~on_input_ready:(fun () -> ())
    ~on_output:(fun _ text -> Buffer.add_string output text) in
  get result; check string "output delivered before exit" "ready\n" (Buffer.contents output); Ok ())
let explicit_cancel () = run_process (fun env path session ->
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import time; time.sleep(60)"] ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> S.cancel ~workspace:path ~actor:"operator" ~login_id:(S.id session) |> get)
    ~on_input_ready:(fun () -> ()) ~on_output:(fun _ _ -> ()) in
  check bool "cancelled promptly" true (result=Error S.Cancelled); Ok ())
let disconnect () = run_process (fun env path session ->
  let closed = ref false in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import time; time.sleep(60)"] ~terminal:false ~is_closed:(fun () -> !closed)
    ~on_ready:(fun () -> closed := true) ~on_input_ready:(fun () -> ()) ~on_output:(fun _ _ -> ()) in
  check bool "disconnect cancels" true (result=Error S.Cancelled); Ok ())
let pipe_eof () = run_process (fun env path session ->
  let acknowledged = ref false in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import sys; sys.stdin.read()"] ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> get (S.submit ~workspace:path ~actor:"operator" ~login_id:(S.id session) (S.Key S.Eof)))
    ~on_input_ready:(fun () ->
      acknowledged := true;
      check bool "input after pipe EOF refused" true
        (S.submit ~workspace:path ~actor:"operator" ~login_id:(S.id session) (S.Text "discarded")=Error S.Not_running))
    ~on_output:(fun _ _ -> ()) in get result;
  check bool "EOF acknowledged" true !acknowledged; Ok ())
let server_shutdown () = run_process (fun env path session ->
  let interrupted = ref false in
  (try Eio.Cancel.sub (fun cancellation ->
     S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
       ~argv:["python3";"-c";"import time; time.sleep(60)"] ~terminal:false ~is_closed:(fun () -> false)
       ~on_ready:(fun () -> Eio.Cancel.cancel cancellation (Failure "fixture server shutdown"))
       ~on_input_ready:(fun () -> ()) ~on_output:(fun _ _ -> ()) |> get)
   with Eio.Cancel.Cancelled _ -> interrupted := true);
  check bool "server cancellation propagates after cleanup" true !interrupted;
  Ok ())
let executable_file dir name =
  let path = Filename.concat dir name in
  let channel = open_out path in
  close_out channel;
  Unix.chmod path 0o755;
  path
let with_path value f =
  let old_path = Sys.getenv "PATH" in
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" old_path)
    (fun () -> Unix.putenv "PATH" value; f ())
let python_prefers_the_bundled_release () = temporary (fun root ->
  let bindir = Filename.concat root "bin" in
  Fs_compat.mkdir_p (Filename.concat bindir "python/bin");
  let bundled = executable_file (Filename.concat bindir "python/bin") "python3" in
  temporary (fun other ->
    let _ = executable_file other "python3" in
    with_path other (fun () ->
      check (option string) "bundled wins over PATH" (Some bundled)
        (S.python ~binary:(Filename.concat bindir "masc")))))
let python_falls_back_to_path () = temporary (fun root ->
  let bindir = Filename.concat root "bin" in
  Fs_compat.mkdir_p bindir;
  temporary (fun other ->
    let expected = executable_file other "python3" in
    with_path (":" ^ other) (fun () ->
      check (option string) "empty segments skipped, PATH searched" (Some expected)
        (S.python ~binary:(Filename.concat bindir "masc")))))
let python_missing_without_bundled_or_path () = temporary (fun root ->
  let bindir = Filename.concat root "bin" in
  Fs_compat.mkdir_p bindir;
  with_path "" (fun () ->
    check (option string) "no interpreter anywhere" None
      (S.python ~binary:(Filename.concat bindir "masc"))))
let python_ignores_relative_path_before_workspace_change () = temporary (fun root ->
  let server = Filename.concat root "server" in
  let workspace = Filename.concat root "workspace" in
  let relative_bin = "relative-bin" in
  List.iter (fun base ->
    Fs_compat.mkdir_p (Filename.concat base relative_bin);
    ignore (executable_file (Filename.concat base relative_bin) "python3");
    ignore (executable_file base "python3")) [server; workspace];
  let absolute_bin = Filename.concat root "absolute-bin" in
  Fs_compat.mkdir_p absolute_bin;
  let expected = executable_file absolute_bin "python3" in
  let binary = Filename.concat server "masc" in
  let original_cwd = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Sys.chdir original_cwd) (fun () ->
    Sys.chdir server;
    with_path (":" ^ relative_bin ^ ":.") (fun () ->
      check (option string) "relative-only PATH is not an interpreter" None
        (S.python ~binary));
    with_path (":" ^ relative_bin ^ ":.:" ^ absolute_bin) (fun () ->
      let selected = S.python ~binary in
      check (option string) "absolute interpreter wins over relative decoys"
        (Some expected) selected;
      Sys.chdir workspace;
      match selected with
      | None -> fail "absolute interpreter was not found"
      | Some path ->
        check string "selection keeps its identity from the child cwd"
          (Unix.realpath expected) (Unix.realpath path))))
let () = run "setup-login-session" ["ownership", [test_case "scope and physical account locks" `Quick isolated_scope];
  "process lifetime", [test_case "normal exit" `Quick normal_exit; test_case "cancel" `Quick explicit_cancel;
    test_case "disconnect" `Quick disconnect; test_case "pipe EOF" `Quick pipe_eof; test_case "server shutdown" `Quick server_shutdown];
  "interpreter", [test_case "bundled release preferred" `Quick python_prefers_the_bundled_release;
    test_case "PATH fallback" `Quick python_falls_back_to_path;
    test_case "relative PATH cannot change with the workspace" `Quick
      python_ignores_relative_path_before_workspace_change;
    test_case "missing without bundled or PATH" `Quick python_missing_without_bundled_or_path]]
