open Alcotest
module S = Runtime_setup_login_session
let get = function Ok value -> value | Error e -> fail (S.error_message e)
let temporary f =
  let path = Filename.temp_dir "masc-login-session-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)
let with_session path f = S.with_session ~workspace:path ~actor:(S.Agent "operator") ~account_key:path f |> get
let isolated_scope () = temporary (fun path ->
  with_session path (fun session ->
    check bool "owner can see live session" true (S.is_active ~workspace:path ~actor:(S.Agent "operator") ~login_id:(S.id session));
    check bool "other actor refused" true (S.cancel ~workspace:path ~actor:(S.Agent "other") ~login_id:(S.id session) = Error S.Not_found);
    temporary (fun other -> check bool "other workspace refused" true
      (S.cancel ~workspace:other ~actor:(S.Agent "operator") ~login_id:(S.id session) = Error S.Not_found));
    check bool "duplicate store refused" true
      (S.with_session ~workspace:path ~actor:(S.Agent "another") ~account_key:path (fun _ -> Ok ()) = Error S.Already_running);
    let occupied = S.with_session ~workspace:path ~actor:(S.Agent "operator") ~account_key:"new-provisional" (fun other ->
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
    ~on_output:(function S.Piped (_, text) -> Buffer.add_string output text
                         | S.Screen _ -> fail "a pipe login drew a screen") in
  get result; check string "output delivered before exit" "ready\n" (Buffer.contents output); Ok ())
let saved_login_closes_input () = run_process (fun env path session ->
  let saved = ref false in
  let received = Filename.concat path "received" in
  let pid_file = Filename.concat path "child-pid" in
  let queued = ref false in
  let result = S.run ~saved_login:(fun () -> Ok !saved)
    session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";
      "import os,sys,time\nopen('child-pid','w').write(str(os.getpid()))\n"
      ^ "print('ready',flush=True)\nsys.stdin.readline()\nopen('received','w').write('received')\n"
      ^ "while True: time.sleep(1)\n"]
    ~terminal:true ~is_closed:(fun () -> false) ~on_ready:(fun () -> ())
    ~on_input_ready:(fun () -> ()) ~on_output:(fun _ ->
      if not !queued && Sys.file_exists pid_file then (
        queued := true; saved := true;
        S.submit ~workspace:path ~actor:(S.Agent "operator") ~login_id:(S.id session)
          (S.Text "synthetic-login-code") |> get)) in
  get result;
  check bool "input was queued at login completion" true !queued;
  check bool "code never reaches the conversation" false (Sys.file_exists received);
  check bool "completed login rejects new input" true
    (S.submit ~workspace:path ~actor:(S.Agent "operator") ~login_id:(S.id session)
       (S.Text "late-code") = Error S.Not_running);
  let pid = Fs_compat.load_file pid_file |> int_of_string in
  let alive = try Unix.kill pid 0; true with Unix.Unix_error (Unix.ESRCH, _, _) -> false in
  check bool "interactive client is reaped before capture" false alive;
  Ok ())
let saved_login_without_terminal_output () = run_process (fun env path session ->
  let saved = Filename.concat path "saved" in
  let result = S.run ~saved_login:(fun () -> Ok (Sys.file_exists saved))
    session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import time\nopen('saved','w').write('saved')\nwhile True: time.sleep(1)\n"]
    ~terminal:true ~is_closed:(fun () -> false) ~on_ready:(fun () -> ())
    ~on_input_ready:(fun () -> ()) ~on_output:(fun _ -> ()) in
  get result; Ok ())
let failed_login_observation () = run_process (fun env path session ->
  let result = S.run ~saved_login:(fun () -> Error "selected login unreadable")
    session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import time\nwhile True: time.sleep(1)\n"]
    ~terminal:true ~is_closed:(fun () -> false) ~on_ready:(fun () -> ())
    ~on_input_ready:(fun () -> ()) ~on_output:(fun _ -> ()) in
  check bool "unreadable login is not successful completion" true
    (result = Error (S.Completion_failed "selected login unreadable")); Ok ())
(* The program overwrites a line the way a full-screen login redraws: a
   carriage return, then the cursor moved up. The screen shows the result,
   not the bytes, in the size the PTY reports, and a line longer than the
   screen, which the terminal wrapped, stays one line. *)
let terminal_screen () = run_process (fun env path session ->
  let screen = ref None in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";
           "import os,sys\nsize=os.get_terminal_size(0)\n"
           ^ "sys.stdout.write('%d %d\\nwait\\rdone\\nlast\\n' % (size.lines, size.columns)"
           ^ " + 'a' * 90 + '\\n\\x1b[3A\\rup')"]
    ~terminal:true ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> ()) ~on_input_ready:(fun () -> ())
    ~on_output:(function S.Screen text -> screen := Some text
                         | S.Piped _ -> fail "a terminal login wrote to a pipe") in
  get result;
  let plain text =
    (* Drop the SGR styles, each ESC up to its final 'm': this checks what
       the screen shows. *)
    let buffer = Buffer.create (String.length text) in
    let rec copy i =
      if i < String.length text then
        if text.[i] = '\027' then
          Option.iter (fun m -> copy (m + 1)) (String.index_from_opt text i 'm')
        else (Buffer.add_char buffer text.[i]; copy (i + 1)) in
    copy 0; Buffer.contents buffer in
  check (option string) "the last screen, as a terminal shows it"
    (Some ("24 80\ndone\nupst\n" ^ String.make 90 'a')) (Option.map plain !screen);
  Ok ())
let explicit_cancel () = run_process (fun env path session ->
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import time; time.sleep(60)"] ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> S.cancel ~workspace:path ~actor:(S.Agent "operator") ~login_id:(S.id session) |> get)
    ~on_input_ready:(fun () -> ()) ~on_output:(fun _ -> ()) in
  check bool "cancelled promptly" true (result=Error S.Cancelled); Ok ())
let disconnect () = run_process (fun env path session ->
  let closed = ref false in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import time; time.sleep(60)"] ~terminal:false ~is_closed:(fun () -> !closed)
    ~on_ready:(fun () -> closed := true) ~on_input_ready:(fun () -> ()) ~on_output:(fun _ -> ()) in
  check bool "disconnect cancels" true (result=Error S.Cancelled); Ok ())
let pipe_eof () = run_process (fun env path session ->
  let acknowledged = ref false in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";"import sys; sys.stdin.read()"] ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> get (S.submit ~workspace:path ~actor:(S.Agent "operator") ~login_id:(S.id session) (S.Key S.Eof)))
    ~on_input_ready:(fun () ->
      acknowledged := true;
      check bool "input after pipe EOF refused" true
        (S.submit ~workspace:path ~actor:(S.Agent "operator") ~login_id:(S.id session) (S.Text "discarded")=Error S.Not_running))
    ~on_output:(fun _ -> ()) in get result;
  check bool "EOF acknowledged" true !acknowledged; Ok ())
let server_shutdown () = run_process (fun env path session ->
  let interrupted = ref false in
  (try Eio.Cancel.sub (fun cancellation ->
     S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
       ~argv:["python3";"-c";"import time; time.sleep(60)"] ~terminal:false ~is_closed:(fun () -> false)
       ~on_ready:(fun () -> Eio.Cancel.cancel cancellation (Failure "fixture server shutdown"))
       ~on_input_ready:(fun () -> ()) ~on_output:(fun _ -> ()) |> get)
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
let hint_testable =
  testable
    (fun fmt -> function
      | S.Auth_url { url } -> Format.fprintf fmt "Auth_url(%S)" url
      | S.Device_code { code; verification_uri } ->
        Format.fprintf fmt "Device_code(%S, %s)" code
          (match verification_uri with Some u -> u | None -> "None"))
    ( = )

let auth_hint_extraction () =
  let styled =
    "\027[1;36mOpen\027[0m (\027]8;;https://auth.openai.com/codex/device\027\\link\027]8;;\027\\) \
     or https://auth.openai.com/codex/device.\n\
     One-time code: \027[1mA1B2-C3D4E\027[0m (not 2026-1124, not http://insecure.example/x)\n"
  in
  check string "ANSI stripped cleanly"
    "Open (link) or https://auth.openai.com/codex/device.\n\
     One-time code: A1B2-C3D4E (not 2026-1124, not http://insecure.example/x)\n"
    (S.strip_ansi styled);
  check (list hint_testable) "OSC 8 + plain URL deduplicated and device code paired with URI"
    [ S.Auth_url { url = "https://auth.openai.com/codex/device" }
    ; S.Device_code
        { code = "A1B2-C3D4E"; verification_uri = Some "https://auth.openai.com/codex/device" }
    ]
    (S.extract_auth_hints styled);
  let github_box =
    "│ Visit https://github.com/login/device │\n│ Enter code: WDJB-MJHT │\n"
  in
  check (list hint_testable) "box-drawing UTF-8 terminates URL and extracts 4-4 device code"
    [ S.Auth_url { url = "https://github.com/login/device" }
    ; S.Device_code
        { code = "WDJB-MJHT"; verification_uri = Some "https://github.com/login/device" }
    ]
    (S.extract_auth_hints github_box);
  check (list hint_testable) "uppercase hyphenated banners without OAuth/device context produce no device code"
    []
    (S.extract_auth_hints "Status: HTTP-4000 UTF8-JSON EXIT-CODE AUTH-CODE USER-CODE:\n");
  check (list hint_testable) "label token ending in colon is ignored while device code is extracted"
    [ S.Device_code { code = "WDJB-MJHT"; verification_uri = None } ]
    (S.extract_auth_hints "Enter USER-CODE: WDJB-MJHT\n");
  let userinfo_url = "https://" ^ "operator:" ^ "redacted" ^ "@auth.openai.com/codex/device" in
  check (list hint_testable) "URLs with inline userinfo credentials are rejected"
    []
    (S.extract_auth_hints ("Open " ^ userinfo_url ^ " and https://operator@auth.openai.com/codex/device\n"));
  check (list hint_testable) "device code following an auth URL without cue words still extracts"
    [ S.Auth_url { url = "https://auth.openai.com/codex/device" }
    ; S.Device_code
        { code = "A1B2-C3D4E"; verification_uri = Some "https://auth.openai.com/codex/device" }
    ]
    (S.extract_auth_hints "https://auth.openai.com/codex/device\nA1B2-C3D4E\n")

let piped_auth_hints_multiline_device_code () = run_process (fun env path session ->
  let hints = ref [] in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";
           "import sys,time\n"
           ^ "sys.stdout.write('Status: HTTP-4000 EXIT-CODE\\n2. Enter this one-time code (expires in 15 minutes)\\n')\nsys.stdout.flush()\ntime.sleep(0.05)\n"
           ^ "sys.stdout.write('   A1B2-C3D4E\\n')\nsys.stdout.flush()\ntime.sleep(0.05)\n"
           ^ "sys.stdout.write('1. Open https://auth.openai.com/codex/device\\n')\nsys.stdout.flush()\ntime.sleep(0.05)\n"
           ^ "sys.stdout.write('   WDJB-MJHT\\n')\nsys.stdout.flush()\n"]
    ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> ()) ~on_input_ready:(fun () -> ())
    ~on_auth_hint:(fun h -> hints := !hints @ [ h ])
    ~on_output:(fun _ -> ()) in
  get result;
  check (list hint_testable) "piped device codes respect line order within and across reads"
    [ S.Device_code { code = "A1B2-C3D4E"; verification_uri = None }
    ; S.Auth_url { url = "https://auth.openai.com/codex/device" }
    ; S.Device_code
        { code = "WDJB-MJHT"; verification_uri = Some "https://auth.openai.com/codex/device" }
    ]
    !hints;
  Ok ())

let piped_auth_hints_dedup_and_chunk_reassembly () = run_process (fun env path session ->
  let hints = ref [] in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";
           "import sys,time\n"
           ^ "sys.stdout.write('Visit https://auth.openai')\nsys.stdout.flush()\ntime.sleep(0.05)\n"
           ^ "sys.stdout.write('.com/codex/device\\nCode: A1B2-C3D4E\\n')\nsys.stdout.flush()\n"
           ^ "sys.stdout.write('Visit https://auth.openai.com/codex/device\\nCode: A1B2-C3D4E\\n')\nsys.stdout.flush()\n"]
    ~terminal:false ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> ()) ~on_input_ready:(fun () -> ())
    ~on_auth_hint:(fun h -> hints := !hints @ [ h ])
    ~on_output:(fun _ -> ()) in
  get result;
  check (list hint_testable) "split URL reassembled and repeated hints deduplicated"
    [ S.Auth_url { url = "https://auth.openai.com/codex/device" }
    ; S.Device_code
        { code = "A1B2-C3D4E"; verification_uri = Some "https://auth.openai.com/codex/device" }
    ]
    !hints;
  Ok ())

let terminal_auth_hints_dedup_across_redraws () = run_process (fun env path session ->
  let hints = ref [] in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";
           "import sys,time\n"
           ^ "for frame in ('|', '/', '-'):\n"
           ^ "  sys.stdout.write('\\x1b[2J\\x1b[H\\x1b[32mhttps://claude.ai/oauth/authorize?code=true\\x1b[0m\\nCode: WDJB-MJHT ' + frame)\n"
           ^ "  sys.stdout.flush()\n  time.sleep(0.03)\n"]
    ~terminal:true ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> ()) ~on_input_ready:(fun () -> ())
    ~on_auth_hint:(fun h -> hints := !hints @ [ h ])
    ~on_output:(fun _ -> ()) in
  get result;
  check (list hint_testable) "PTY redraws emit each URL and code once"
    [ S.Auth_url { url = "https://claude.ai/oauth/authorize?code=true" }
    ; S.Device_code
        { code = "WDJB-MJHT"; verification_uri = Some "https://claude.ai/oauth/authorize?code=true" }
    ]
    !hints;
  Ok ())

let terminal_auth_hints_split_url_no_half_emit () = run_process (fun env path session ->
  let hints = ref [] in
  let result = S.run session ~env ~child_env:(Unix.environment ()) ~cwd:path
    ~argv:["python3";"-c";
           "import sys,time\n"
           ^ "sys.stdout.write('Visit https://auth.openai')\nsys.stdout.flush()\ntime.sleep(0.05)\n"
           ^ "sys.stdout.write('.com/codex/device')\nsys.stdout.flush()\ntime.sleep(0.05)\n"
           ^ "sys.stdout.write('\\r\\nCode: A1B2-C3D4E\\r\\n')\nsys.stdout.flush()\n"]
    ~terminal:true ~is_closed:(fun () -> false)
    ~on_ready:(fun () -> ()) ~on_input_ready:(fun () -> ())
    ~on_auth_hint:(fun h -> hints := !hints @ [ h ])
    ~on_output:(fun _ -> ()) in
  get result;
  check (list hint_testable) "PTY split URL waits for completion and never emits truncated prefix"
    [ S.Auth_url { url = "https://auth.openai.com/codex/device" }
    ; S.Device_code
        { code = "A1B2-C3D4E"; verification_uri = Some "https://auth.openai.com/codex/device" }
    ]
    !hints;
  Ok ())

let () = run "setup-login-session" ["ownership", [test_case "scope and physical account locks" `Quick isolated_scope];
  "process lifetime", [test_case "normal exit" `Quick normal_exit;
    test_case "saved login closes input and reaps client" `Quick saved_login_closes_input;
    test_case "browser login finishes without terminal activity" `Quick saved_login_without_terminal_output;
    test_case "failed login observation" `Quick failed_login_observation;
    test_case "terminal screen" `Quick terminal_screen; test_case "cancel" `Quick explicit_cancel;
    test_case "disconnect" `Quick disconnect; test_case "pipe EOF" `Quick pipe_eof; test_case "server shutdown" `Quick server_shutdown];
  "auth hints", [
    test_case "ANSI stripping and structured extraction" `Quick auth_hint_extraction;
    test_case "piped multi-chunk device code preserves context" `Quick piped_auth_hints_multiline_device_code;
    test_case "piped chunk reassembly and deduplication" `Quick piped_auth_hints_dedup_and_chunk_reassembly;
    test_case "terminal redraws deduplicated per session" `Quick terminal_auth_hints_dedup_across_redraws;
    test_case "terminal split URL does not emit truncated prefix" `Quick terminal_auth_hints_split_url_no_half_emit];
  "interpreter", [test_case "bundled release preferred" `Quick python_prefers_the_bundled_release;
    test_case "PATH fallback" `Quick python_falls_back_to_path;
    test_case "relative PATH cannot change with the workspace" `Quick
      python_ignores_relative_path_before_workspace_change;
    test_case "missing without bundled or PATH" `Quick python_missing_without_bundled_or_path]]
