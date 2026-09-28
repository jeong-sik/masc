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
let () = run "setup-login-session" ["ownership", [test_case "scope and physical account locks" `Quick isolated_scope];
  "process lifetime", [test_case "normal exit" `Quick normal_exit; test_case "cancel" `Quick explicit_cancel;
    test_case "disconnect" `Quick disconnect; test_case "pipe EOF" `Quick pipe_eof; test_case "server shutdown" `Quick server_shutdown]]
