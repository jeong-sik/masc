open Alcotest

(* Tests for the masc-exec-shim library (Phase 1 SSH remote execution lane,
   spec §4.2).  The kill policy and status mapping are asserted as pure
   decisions, with no real signals.  Config and env file tests read real files
   in temporary directories; the FIFO case reads in a forked child under an
   alarm, so a read that blocks fails the test instead of hanging it. *)

let show_kill_action = function
  | Exec_shim.Sigterm_pgid -> "Sigterm_pgid"
  | Exec_shim.Wait_grace g -> Printf.sprintf "Wait_grace %g" g
  | Exec_shim.Sigkill_pgid -> "Sigkill_pgid"

let kill_action = testable (fun fmt a -> Format.pp_print_string fmt (show_kill_action a)) ( = )

let shim_env = [ ("HOME", "/home/dev")
               ; ("USER", "dev")
               ; ("TMPDIR", "/scratch")
               ; ("SSH_CONNECTION", "10.0.0.1 22 10.0.0.2 2222")
               ; ("SHELL", "/bin/bash") ]

(* {1 env synthesis} *)

let test_minimal_base_env () =
  let env = Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:[] ~request_env:[] in
  check (option string) "PATH is the fixed minimal value"
    (Some Exec_shim.default_base_path) (List.assoc_opt "PATH" env);
  check (option string) "HOME from shim env" (Some "/home/dev") (List.assoc_opt "HOME" env);
  check (option string) "USER from shim env" (Some "dev") (List.assoc_opt "USER" env);
  check (option string) "TMPDIR from shim env" (Some "/scratch") (List.assoc_opt "TMPDIR" env);
  check int "base env is exactly PATH/HOME/USER/TMPDIR" 4 (List.length env)

let test_base_env_defaults () =
  let env = Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:Exec_shim.default_base_path ~base_env:[] ~allowlist:[] ~request_env:[] in
  check (option string) "HOME default" (Some "/tmp") (List.assoc_opt "HOME" env);
  check (option string) "USER default" (Some "masc") (List.assoc_opt "USER" env);
  check (option string) "TMPDIR default" (Some "/tmp") (List.assoc_opt "TMPDIR" env)

let test_allowlist_overlay_survives () =
  let env = Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:[ "FOO" ]
      ~request_env:[ ("FOO", "ok"); ("BAR", "not-allowlisted") ] in
  check (option string) "allowlisted FOO kept" (Some "ok") (List.assoc_opt "FOO" env);
  check (option string) "non-allowlisted BAR dropped" None (List.assoc_opt "BAR" env)

let test_runtime_identity_env_survives_empty_allowlist () =
  let env =
    Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:[]
      ~request_env:
        [ "GH_CONFIG_DIR", "/srv/masc/playground/keeper-a/.config/gh"
        ; "GIT_TERMINAL_PROMPT", "0"
        ; "GIT_AUTHOR_NAME", "keeper-a"
        ; "GIT_COMMITTER_NAME", "keeper-a"
        ; "LANG", "C"
        ]
  in
  check (option string) "runtime GitHub identity kept"
    (Some "/srv/masc/playground/keeper-a/.config/gh")
    (List.assoc_opt "GH_CONFIG_DIR" env);
  check (option string) "runtime prompt guard kept" (Some "0")
    (List.assoc_opt "GIT_TERMINAL_PROMPT" env);
  check (option string) "runtime commit author kept" (Some "keeper-a")
    (List.assoc_opt "GIT_AUTHOR_NAME" env);
  check (option string) "runtime commit committer kept" (Some "keeper-a")
    (List.assoc_opt "GIT_COMMITTER_NAME" env);
  check (option string) "ordinary caller env still needs allowlisting" None
    (List.assoc_opt "LANG" env)

let test_denylist_beats_allowlist () =
  let env = Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:Exec_shim.default_base_path ~base_env:[]
      ~allowlist:[ "PATH"; "FOO" ]
      ~request_env:[ ("PATH", "/evil/bin"); ("FOO", "ok") ] in
  check bool "wire PATH dropped" true (List.assoc_opt "PATH" env <> Some "/evil/bin");
  check (option string) "FOO kept" (Some "ok") (List.assoc_opt "FOO" env)

let test_denylist_names () =
  let wire = [ ("PATH", "/evil/bin")
             ; ("HOME", "/evil/home")
             ; ("LD_PRELOAD", "/evil.so")
             ; ("LD_LIBRARY_PATH", "/evil/lib")
             ; ("DYLD_INSERT_LIBRARIES", "/evil.dylib")
             ; ("DYLD_PRINT_LIBRARIES", "1")
             ; ("BASH_ENV", "/evil.sh")
             ; ("ENV", "/evil.sh") ] in
  let env = Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:(List.map fst wire)
      ~request_env:wire in
  List.iter
    (fun (k, v) ->
       check bool (k ^ " dropped despite allowlist") true (List.assoc_opt k env <> Some v))
    wire;
  check (option string) "base HOME survives wire HOME" (Some "/home/dev")
    (List.assoc_opt "HOME" env)

let test_denylisted_predicate () =
  List.iter (fun n -> check bool n true (Exec_shim.denylisted_env_name n))
    [ "PATH"; "HOME"; "LD_PRELOAD"; "LD_LIBRARY_PATH"; "BASH_ENV"; "ENV"; "DYLD_X" ];
  List.iter (fun n -> check bool n false (Exec_shim.denylisted_env_name n))
    [ "FOO"; "DYLD"; "path"; "HOMEBREW_PREFIX"; "ENVIRONMENT" ]

(* {1 kill policy} *)

let test_kill_policy_on_eof () =
  check (list kill_action) "SIGTERM pgid -> grace -> SIGKILL pgid"
    Exec_shim.[ Sigterm_pgid; Wait_grace kill_grace_sec; Sigkill_pgid ]
    (Exec_shim.kill_policy Exec_shim.On_eof)

let test_kill_policy_on_timeout () =
  check (list kill_action) "timeout uses the same escalation"
    Exec_shim.[ Sigterm_pgid; Wait_grace kill_grace_sec; Sigkill_pgid ]
    (Exec_shim.kill_policy Exec_shim.On_timeout)

let test_kill_policy_on_child_exit () =
  check (list kill_action) "child exit only reaps leftover group members"
    Exec_shim.[ Sigkill_pgid ] (Exec_shim.kill_policy Exec_shim.On_child_exit)

(* {1 waitpid status -> trailer} *)

let trailer_exit t = t.Exec_ssh_protocol.exit
let trailer_signal t = t.Exec_ssh_protocol.signal
let trailer_timed_out t = t.Exec_ssh_protocol.timed_out
let trailer_shim_error t = t.Exec_ssh_protocol.shim_error

let test_trailer_of_status_exit () =
  let t = Exec_shim.trailer_of_status ~v:Exec_ssh_protocol.newest ~timed_out:false (Unix.WEXITED 7) in
  check (option int) "exit" (Some 7) (trailer_exit t);
  check (option int) "signal" None (trailer_signal t);
  check bool "timed_out" false (trailer_timed_out t);
  check (option string) "shim_error" None (trailer_shim_error t);
  (* must satisfy the codec's trailer invariants *)
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' -> check (option int) "roundtrip exit" (Some 7) t'.Exec_ssh_protocol.exit

let test_trailer_of_status_signal_timeout () =
  (* WSIGNALED carries OCaml's abstract signal code (Sys.sigterm = -11);
     the trailer must carry the host OS number (15 on Linux/macOS). *)
  let t = Exec_shim.trailer_of_status ~v:Exec_ssh_protocol.newest ~timed_out:true (Unix.WSIGNALED Sys.sigterm) in
  check (option int) "exit" None (trailer_exit t);
  check (option int) "signal" (Some 15) (trailer_signal t);
  check bool "timed_out" true (trailer_timed_out t);
  match Exec_ssh_protocol.parse_trailer (Exec_ssh_protocol.render_trailer t) with
  | Error e -> fail e
  | Ok t' ->
    check (option int) "roundtrip signal" (Some 15) t'.Exec_ssh_protocol.signal;
    check bool "roundtrip timed_out" true t'.Exec_ssh_protocol.timed_out

let test_host_signal_number () =
  check int "SIGKILL" 9 (Exec_shim.host_signal_number Sys.sigkill);
  check int "SIGTERM" 15 (Exec_shim.host_signal_number Sys.sigterm);
  check int "SIGINT" 2 (Exec_shim.host_signal_number Sys.sigint)

(* {1 config file} *)

let test_parse_config_ok () =
  let content = "# masc-exec-shim test config\n\nremote_root=/srv/masc/playground\nenv_allowlist=FOO, BAR ,BAZ\n" in
  match Exec_shim.parse_config content with
  | Error e -> fail e
  | Ok c ->
    check string "remote_root" "/srv/masc/playground" c.Exec_shim.remote_root;
    check (list string) "env_allowlist" [ "FOO"; "BAR"; "BAZ" ] c.Exec_shim.env_allowlist;
    check (list string) "payload path defaults to the fixed base"
      Exec_shim.default_payload_path c.Exec_shim.payload_path

(* RFC-0422: the box. *)
let has_code code message =
  let n = String.length code and h = String.length message in
  let rec scan i = i + n <= h && (String.sub message i n = code || scan (i + 1)) in
  scan 0

let plan_label = function
  | Exec_shim.Run_effect -> "effect"
  | Exec_shim.Run_boxed { deny_fs = true; deny_net = true } -> "boxed:fs+net"
  | Exec_shim.Run_boxed { deny_fs = false; deny_net = true } -> "boxed:net"
  | Exec_shim.Run_boxed { deny_fs = true; deny_net = false } -> "boxed:fs"
  | Exec_shim.Run_boxed { deny_fs = false; deny_net = false } -> "boxed:none"
  | Exec_shim.Refuse_observe_unsupported -> "refuse"

let test_plan_for_mode () =
  let plan ~supported mode = plan_label (Exec_shim.plan_for_mode ~supported mode) in
  check string "effect runs unboxed on a supporting host" "effect"
    (plan ~supported:true Exec_ssh_protocol.Effect);
  check string "effect runs unboxed on an unsupporting host too" "effect"
    (plan ~supported:false Exec_ssh_protocol.Effect);
  check string "observe denies writes and sockets" "boxed:fs+net"
    (plan ~supported:true Exec_ssh_protocol.Observe);
  check string "guest_local denies sockets only" "boxed:net"
    (plan ~supported:true Exec_ssh_protocol.Guest_local);
  check string "observe on an unsupporting host is refused, not unboxed" "refuse"
    (plan ~supported:false Exec_ssh_protocol.Observe);
  check string "guest_local on an unsupporting host is refused too" "refuse"
    (plan ~supported:false Exec_ssh_protocol.Guest_local)

let test_scratch_env () =
  let env = Exec_shim.scratch_env ~scratch:"/tmp/masc-observe-1-abc"
      [ "HOME", "/home/keeper"; "PATH", "/usr/bin"; "TMPDIR", "/tmp" ] in
  check (option string) "HOME is the scratch" (Some "/tmp/masc-observe-1-abc") (List.assoc_opt "HOME" env);
  check (option string) "TMPDIR is the scratch" (Some "/tmp/masc-observe-1-abc") (List.assoc_opt "TMPDIR" env);
  check (option string) "PATH is untouched" (Some "/usr/bin") (List.assoc_opt "PATH" env);
  check int "no duplicate names" 3 (List.length env)

let test_parse_config_scratch_root () =
  (match Exec_shim.parse_config "remote_root=/srv/masc
scratch_root=/tmp/masc-scratch
" with
   | Ok c -> check string "scratch_root" "/tmp/masc-scratch" c.Exec_shim.scratch_root
   | Error e -> fail e);
  (match Exec_shim.parse_config "remote_root=/srv/masc
" with
   | Ok c -> check string "absent scratch_root is the shared default" Exec_ssh_protocol.default_scratch_root c.Exec_shim.scratch_root
   | Error e -> fail e);
  (match Exec_shim.parse_config "remote_root=/srv/masc
scratch_root=relative/dir
" with
   | Ok _ -> fail "relative scratch_root accepted"
   | Error e -> check bool "relative scratch_root is a config error" true
                  (has_code Exec_shim.config_error_code e));
  match Exec_shim.parse_config "remote_root=/srv/masc
scratch_root=
" with
  | Ok _ -> fail "empty scratch_root accepted"
  | Error e -> check bool "empty scratch_root is a config error" true
                 (has_code Exec_shim.config_error_code e)

let test_observe_support_is_consistent () =
  (* The probe and the plan read the same kernel answer; off Linux it is no. *)
  let supported = Exec_shim.observe_supported () in
  if Sys.os_type <> "Unix" || not (Sys.file_exists "/proc/version")
  then check bool "no Landlock outside Linux" false supported

let test_user_notif_support_is_consistent () =
  (* Task-1568 (#36032 follow-up, review 5192723206): the capability probe
     for a future observation path. Same invariant as
     [test_observe_support_is_consistent] — false off Linux — plus the
     probe must never raise: it forks and waits on a throwaway child that
     runs no payload, so an exception here means the fork/wait bookkeeping
     itself is broken, not that the kernel lacks the feature (a kernel
     that lacks it, or a seccomp policy above this process that filters
     seccomp(2) itself — e.g. running inside masc's own Execute sandbox —
     is a plain [false], never a raised exception). *)
  match Exec_shim.user_notif_supported () with
  | supported ->
    if Sys.os_type <> "Unix" || not (Sys.file_exists "/proc/version")
    then check bool "no seccomp listener support outside Linux" false supported
  | exception exn ->
    fail ("user_notif_supported raised: " ^ Printexc.to_string exn)

let test_parse_config_path_ok () =
  let content =
    "remote_root=/masc-work\npath=/home/opam/.opam/5.5/bin:/usr/local/bin:/usr/bin:/bin\n"
  in
  match Exec_shim.parse_config content with
  | Error e -> fail e
  | Ok c ->
    check (list string) "payload path from config"
      [ "/home/opam/.opam/5.5/bin"; "/usr/local/bin"; "/usr/bin"; "/bin" ]
      c.Exec_shim.payload_path

let test_parse_config_rejects_bad_path () =
  List.iter
    (fun (label, content) ->
      match Exec_shim.parse_config content with
      | Ok _ -> fail (label ^ " must be rejected")
      | Error e ->
        check bool (label ^ " config error code") true
          (String.starts_with ~prefix:"remote_ssh_shim_config_error" e))
    [ "relative entry", "remote_root=/masc-work\npath=/usr/bin:relative/bin\n"
    ; "empty entry", "remote_root=/masc-work\npath=/usr/bin::/bin\n"
    ; "empty path", "remote_root=/masc-work\npath=\n"
    ]

let test_synthesize_env_takes_config_path () =
  let env =
    Exec_shim.synthesize_env ~endpoint_env:Exec_shim.no_endpoint_env ~path:"/home/opam/.opam/5.5/bin:/usr/bin"
      ~base_env:shim_env ~allowlist:[] ~request_env:[ ("PATH", "/wire/bin") ]
  in
  check (option string) "config path replaces the fixed base"
    (Some "/home/opam/.opam/5.5/bin:/usr/bin") (List.assoc_opt "PATH" env)

let test_parse_config_requires_root () =
  match Exec_shim.parse_config "env_allowlist=FOO\n" with
  | Ok _ -> fail "missing remote_root must be rejected"
  | Error e ->
    check bool "config error code" true
      (String.starts_with ~prefix:"remote_ssh_shim_config_error" e)

let test_parse_config_rejects_relative_root () =
  match Exec_shim.parse_config "remote_root=relative/path\n" with
  | Ok _ -> fail "relative remote_root must be rejected"
  | Error e ->
    check bool "config error code" true
      (String.starts_with ~prefix:"remote_ssh_shim_config_error" e)

let test_parse_config_rejects_unknown_key () =
  match Exec_shim.parse_config "remote_root=/srv/masc\nbogus=1\n" with
  | Ok _ -> fail "unknown keys must be rejected (typo-safe config)"
  | Error e ->
    check bool "config error code" true
      (String.starts_with ~prefix:"remote_ssh_shim_config_error" e)

(* {1 endpoint env file} *)

let env_file_fixture_path = "/etc/masc-exec-shim.env"

let endpoint_env_of content =
  match Exec_shim.parse_env_file ~path:env_file_fixture_path content with
  | Ok env -> env
  | Error e -> fail ("env file fixture rejected: " ^ e)

let declared (env : Exec_shim.endpoint_env) =
  List.sort compare (env :> (string * string) list)

let is_config_error e = String.starts_with ~prefix:Exec_shim.config_error_code e

let test_env_file_declares_values_verbatim () =
  let env =
    endpoint_env_of
      (String.concat "\n"
         [ "# written from the task image"
         ; ""
         ; "VIRTUAL_ENV=/opt/venv"
         ; "LD_LIBRARY_PATH=/usr/local/cuda/lib64"
         ; "PS1=\\u@\\h $ "
         ; "JAVA_OPTS=-Dkey=value"
         ; "EMPTY="
         ; "  # an indented comment"
         ; "" ])
  in
  check (list (pair string string)) "each name with the rest of its line"
    [ "EMPTY", ""
    ; "JAVA_OPTS", "-Dkey=value"
    ; "LD_LIBRARY_PATH", "/usr/local/cuda/lib64"
    ; "PS1", "\\u@\\h $ "
    ; "VIRTUAL_ENV", "/opt/venv" ]
    (declared env)

(* docker reads the file with bufio.ScanLines, which drops the '\r' of a CRLF
   ending; a file with CRLF line endings declares the same values. *)
let test_env_file_crlf_lines () =
  let env =
    endpoint_env_of
      "# written on Windows\r\n\r\nVIRTUAL_ENV=/opt/venv\r\n  # indented\r\nJAVA_OPTS=-Dkey=value\r\nLAST=x\r"
  in
  check (list (pair string string)) "values end before the '\\r'"
    [ "JAVA_OPTS", "-Dkey=value"; "LAST", "x"; "VIRTUAL_ENV", "/opt/venv" ]
    (declared env);
  check (list (pair string string)) "only one '\\r' is the line ending"
    [ "A", "x\r" ] (declared (endpoint_env_of "A=x\r\r\n"))

let test_env_file_rejects () =
  List.iter
    (fun (label, content) ->
      match Exec_shim.parse_env_file ~path:env_file_fixture_path content with
      | Ok _ -> fail (label ^ " must be rejected")
      | Error e -> check bool (label ^ " is a config error") true (is_config_error e))
    [ "PATH", "PATH=/opt/venv/bin:/usr/bin\n"
    ; "a name without a value", "VIRTUAL_ENV\n"
    ; "an indented name", "  VIRTUAL_ENV=/opt/venv\n"
    ; "a name starting with a digit", "1X=y\n"
    ; "a dash in the name", "MY-VAR=y\n"
    ; "an empty name", "=y\n"
    ; "a name declared twice", "A=1\nA=2\n"
    ; "a NUL byte in the value", "A=x\000y\n"
    ; "a GitHub token", "GH_TOKEN=ghp_x\n"
    ; "a GitHub Enterprise token", "GITHUB_ENTERPRISE_TOKEN=x\n"
    ; "the runner's GitHub config dir", "GH_CONFIG_DIR=/root/.config/gh\n"
    ; "the runner's prompt guard", "GIT_TERMINAL_PROMPT=1\n"
    ; "the runner's commit author", "GIT_AUTHOR_NAME=someone\n"
    ; "the runner's commit committer", "GIT_COMMITTER_NAME=someone\n"
    ]

let test_endpoint_env_overlays_the_base () =
  let endpoint_env =
    endpoint_env_of "VIRTUAL_ENV=/opt/venv\nLD_LIBRARY_PATH=/usr/local/cuda/lib64\nHOME=/root\n"
  in
  let env =
    Exec_shim.synthesize_env ~path:"/opt/venv/bin:/usr/bin" ~endpoint_env ~base_env:shim_env
      ~allowlist:[] ~request_env:[]
  in
  check (option string) "a declared name is added" (Some "/opt/venv")
    (List.assoc_opt "VIRTUAL_ENV" env);
  check (option string) "an operator may declare the loader path"
    (Some "/usr/local/cuda/lib64") (List.assoc_opt "LD_LIBRARY_PATH" env);
  check (option string) "a declared HOME replaces the session's" (Some "/root")
    (List.assoc_opt "HOME" env);
  check (option string) "PATH is still path=" (Some "/opt/venv/bin:/usr/bin")
    (List.assoc_opt "PATH" env);
  check int "names stay unique"
    (List.length (List.sort_uniq compare (List.map fst env))) (List.length env)

let test_wire_meets_the_endpoint_env () =
  let endpoint_env =
    endpoint_env_of "VIRTUAL_ENV=/opt/venv\nLD_LIBRARY_PATH=/usr/local/cuda/lib64\nLANG=C.UTF-8\n"
  in
  let env =
    Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~endpoint_env ~base_env:shim_env
      ~allowlist:[ "VIRTUAL_ENV"; "LD_LIBRARY_PATH" ]
      ~request_env:[ "VIRTUAL_ENV", "/work/venv"; "LD_LIBRARY_PATH", "/evil/lib"; "LANG", "fr_FR" ]
  in
  check (option string) "an allowlisted wire value replaces the declared one"
    (Some "/work/venv") (List.assoc_opt "VIRTUAL_ENV" env);
  check (option string) "the denylist still keeps the wire off the loader path"
    (Some "/usr/local/cuda/lib64") (List.assoc_opt "LD_LIBRARY_PATH" env);
  check (option string) "a wire value outside the allowlist leaves the declared one"
    (Some "C.UTF-8") (List.assoc_opt "LANG" env)

let test_parse_config_env_file () =
  (match Exec_shim.parse_config "remote_root=/srv/masc\nenv_file=/etc/masc-exec-shim.env\n" with
   | Ok c ->
     check (option string) "env_file" (Some "/etc/masc-exec-shim.env") c.Exec_shim.env_file
   | Error e -> fail e);
  (match Exec_shim.parse_config "remote_root=/srv/masc\n" with
   | Ok c -> check (option string) "no env_file declares nothing" None c.Exec_shim.env_file
   | Error e -> fail e);
  List.iter
    (fun (label, content) ->
      match Exec_shim.parse_config content with
      | Ok _ -> fail (label ^ " must be rejected")
      | Error e -> check bool (label ^ " is a config error") true (is_config_error e))
    [ "a relative env_file", "remote_root=/srv/masc\nenv_file=etc/masc-exec-shim.env\n"
    ; "an empty env_file", "remote_root=/srv/masc\nenv_file=\n"
    ]

(* {1 path jail} *)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  scan 0

let with_tmp_tree f =
  let root = Filename.temp_dir "exec_shim_jail" "" in
  Unix.mkdir (Filename.concat root "sub") 0o755;
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote root)))
    (fun () -> f root)

(* Mode set, not left to the umask: a config or env file others may write is
   refused. *)
let write_endpoint_file path content =
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc content);
  Unix.chmod path 0o644

(* A malformed line may be a secret pasted in the wrong place. The error leads
   the operator to the line without printing it. *)
let test_env_file_error_names_the_line_not_its_text () =
  let secret = "ghp_0123456789abcdef" in
  let error_of content =
    match Exec_shim.parse_env_file ~path:env_file_fixture_path content with
    | Ok _ -> fail "the fixture must be rejected"
    | Error e -> e
  in
  List.iter
    (fun (label, content, line) ->
      let e = error_of content in
      check bool (label ^ ": names the file and the line") true
        (contains (Printf.sprintf "%s line %d: " env_file_fixture_path line) e);
      check bool (label ^ ": does not print the line") false (contains secret e))
    [ "a line without '='", "A=1\n" ^ secret ^ "\n", 2
    ; "an invalid name", "export " ^ secret ^ "=x\n", 1
    ; "a NUL byte in the value", "TOKEN=" ^ secret ^ "\000\n", 1
    ; "PATH", "\nPATH=/" ^ secret ^ "\n", 2
    ; "a name declared twice", "TOKEN=a\nTOKEN=" ^ secret ^ "\n", 2
    ];
  let e = error_of "TOKEN=a\nOTHER=b\nTOKEN=c\n" in
  check bool "a name declared twice reports both lines" true
    (contains "declared twice, on lines 1 and 3" e);
  check bool "a name declared twice is not printed" false (contains "TOKEN" e)

(* A secret pasted into the config in the wrong place stays out of the error:
   the error names the line or the key and says what is wrong. *)
let test_parse_config_errors_print_no_file_text () =
  let secret = "ghp_0123456789abcdef" in
  List.iter
    (fun (label, content, expected) ->
      match Exec_shim.parse_config content with
      | Ok _ -> fail (label ^ " must be rejected")
      | Error e ->
        check string (label ^ ": the whole error") (Exec_shim.config_error_code ^ ": " ^ expected) e;
        check bool (label ^ ": does not print the file's text") false (contains secret e))
    [ "a line without '='", "remote_root=/srv/masc\n" ^ secret ^ "\n",
      "line 2 is not key=value"
    ; "an unknown key", "remote_root=/srv/masc\n\n" ^ secret ^ "=1\n", "line 3 has an unknown key"
    ; "an unknown key before a malformed line", secret ^ "=1\nnot a pair\n",
      "line 1 has an unknown key"
    ; "a relative remote_root", "remote_root=" ^ secret ^ "\n",
      "remote_root must be an absolute path"
    ; "a relative env_file", "remote_root=/srv/masc\nenv_file=" ^ secret ^ "\n",
      "env_file must be an absolute path"
    ; "an empty path entry", "remote_root=/srv/masc\npath=/" ^ secret ^ "::/bin\n",
      "path has an empty entry"
    ; "a relative path entry", "remote_root=/srv/masc\npath=/usr/bin:" ^ secret ^ "\n",
      "path entries must be absolute"
    ]

let test_read_env_file () =
  (match Exec_shim.read_env_file None with
   | Ok env -> check (list (pair string string)) "no env_file declares nothing" [] (declared env)
   | Error e -> fail e);
  with_tmp_tree (fun root ->
      let env_file = Filename.concat root "shim.env" in
      (match Exec_shim.read_env_file (Some env_file) with
       | Ok _ -> fail "a named env_file that is not there must refuse the request"
       | Error e -> check bool "an absent env_file is a config error" true (is_config_error e));
      write_endpoint_file env_file "VIRTUAL_ENV=/opt/venv\n";
      match Exec_shim.read_env_file (Some env_file) with
      | Ok env ->
        check (list (pair string string)) "the file's declarations"
          [ "VIRTUAL_ENV", "/opt/venv" ] (declared env)
      | Error e -> fail e)

(* The owner and mode rule the config file and an env file share, over
   synthetic uids and modes, so a file owned by another account needs no
   chown. The Terminal-Bench container runs the shim as root with root-owned
   0644 files. *)
let test_endpoint_file_owner_and_mode_rule () =
  let show = function
    | None -> "read"
    | Some (Exec_shim.Owned_by uid) -> Printf.sprintf "owned by uid %d" uid
    | Some (Exec_shim.Writable_by Exec_shim.Its_group) -> "writable by its group"
    | Some (Exec_shim.Writable_by Exec_shim.Every_user) -> "writable by every user"
    | Some (Exec_shim.Writable_by Exec_shim.Its_group_and_every_user) ->
      "writable by its group and every user"
  in
  let shim = 1000 and other = 1001 and root = 0 in
  List.iter
    (fun (label, euid, owner, perm, expected) ->
      check string label expected (show (Exec_shim.refuse_endpoint_file ~euid ~owner ~perm)))
    [ "root-owned 0644", shim, root, 0o644, "read"
    ; "owned by the shim's uid, 0644", shim, shim, 0o644, "read"
    ; "owned by another uid, 0644", shim, other, 0o644, "owned by uid 1001"
    ; "root-owned 0664", shim, root, 0o664, "writable by its group"
    ; "root-owned 0646", shim, root, 0o646, "writable by every user"
    ; "owned by the shim's uid, 0666", shim, shim, 0o666, "writable by its group and every user"
    ; "a root shim, root-owned 0644", root, root, 0o644, "read"
    ; "a root shim, a file another uid owns", root, other, 0o644, "owned by uid 1001"
    ; "another owner is reported before the mode", shim, other, 0o666, "owned by uid 1001"
    ]

(* Only a regular file is read. A plain open of a FIFO nobody writes to blocks
   forever, so that read runs in a child an alarm ends: a regression fails the
   test instead of hanging it. *)
let test_read_env_file_reads_only_a_regular_file () =
  let refused path =
    match Exec_shim.read_env_file (Some path) with
    | Ok _ -> `Read
    | Error e when is_config_error e && contains (path ^ " is not a regular file") e -> `Refused
    | Error _ -> `Refused_for_another_reason
  in
  let alarm_sec = 5 in
  with_tmp_tree (fun root ->
      let fifo = Filename.concat root "shim.env" in
      Unix.mkfifo fifo 0o644;
      (match Unix.fork () with
       | 0 ->
         ignore (Unix.alarm alarm_sec);
         Unix._exit
           (match refused fifo with
            | `Refused -> 0
            | `Read -> 1
            | `Refused_for_another_reason -> 2)
       | child ->
         (match snd (Unix.waitpid [] child) with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED 1 -> fail "a FIFO was read as an env file"
          | Unix.WEXITED _ -> fail "a FIFO was refused, but not as a file that is not regular"
          | Unix.WSIGNALED signal when signal = Sys.sigalrm ->
            fail "reading a FIFO without a writer blocked"
          | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> fail "the reading child was killed"));
      List.iter
        (fun (label, path) ->
          match refused path with
          | `Refused -> ()
          | `Read -> fail (label ^ " was read as an env file")
          | `Refused_for_another_reason ->
            fail (label ^ " was refused, but not as a file that is not regular"))
        [ "a directory", Filename.concat root "sub"; "a character device", "/dev/null" ])

(* Whoever can write the file sets every payload's environment. *)
let test_read_env_file_refuses_a_file_others_may_write () =
  with_tmp_tree (fun root ->
      let env_file = Filename.concat root "shim.env" in
      write_endpoint_file env_file "VIRTUAL_ENV=/opt/venv\n";
      List.iter
        (fun (mode, writers) ->
          Unix.chmod env_file mode;
          let label = Printf.sprintf "mode %04o" mode in
          match Exec_shim.read_env_file (Some env_file) with
          | Ok _ -> fail (label ^ " must refuse the request")
          | Error e ->
            check bool (label ^ " is a config error") true (is_config_error e);
            check bool (label ^ " names the file") true (contains env_file e);
            check bool (label ^ " says who could write it") true
              (contains ("writable by " ^ writers ^ " (") e))
        [ 0o666, "its group and every user"; 0o664, "its group"; 0o646, "every user" ];
      Unix.chmod env_file 0o644;
      match Exec_shim.read_env_file (Some env_file) with
      | Ok env ->
        check (list (pair string string)) "a file only its owner may write is read"
          [ "VIRTUAL_ENV", "/opt/venv" ] (declared env)
      | Error e -> fail e)

(* Whoever can write the config names the payload PATH and the env file. *)
let test_read_config_file_refuses_a_file_others_may_write () =
  with_tmp_tree (fun root ->
      let config_file = Filename.concat root "shim.conf" in
      write_endpoint_file config_file (Printf.sprintf "remote_root=%s\n" root);
      List.iter
        (fun (mode, writers) ->
          Unix.chmod config_file mode;
          let label = Printf.sprintf "mode %04o" mode in
          match Exec_shim.read_config_file config_file with
          | Ok _ -> fail (label ^ " must refuse the config")
          | Error e ->
            check bool (label ^ " is a config error") true (is_config_error e);
            check bool (label ^ " names the config file") true
              (contains ("config file " ^ config_file) e);
            check bool (label ^ " says who could write it") true
              (contains ("writable by " ^ writers ^ " (") e))
        [ 0o666, "its group and every user"; 0o664, "its group"; 0o646, "every user" ];
      Unix.chmod config_file 0o644;
      match Exec_shim.read_config_file config_file with
      | Ok config ->
        check string "a file only its owner may write is read" root config.Exec_shim.remote_root
      | Error e -> fail e)

(* Every way out of the reader closes the descriptor it opened: a refused mode,
   a path that is not a regular file, a missing file, and a read. Counted from
   the descriptor table, since a leak returns no error. *)
let test_endpoint_file_reads_leave_no_descriptor_open () =
  let open_descriptors () = Array.length (Sys.readdir "/dev/fd") in
  with_tmp_tree (fun root ->
      let env_file = Filename.concat root "shim.env" in
      write_endpoint_file env_file "VIRTUAL_ENV=/opt/venv\n";
      let before = open_descriptors () in
      let reads =
        [ "a read", (fun () -> Exec_shim.read_env_file (Some env_file))
        ; "a directory", (fun () -> Exec_shim.read_env_file (Some (Filename.concat root "sub")))
        ; "a missing file", (fun () -> Exec_shim.read_env_file (Some (Filename.concat root "absent")))
        ; ( "a refused mode"
          , fun () ->
              Unix.chmod env_file 0o664;
              Exec_shim.read_env_file (Some env_file) )
        ]
      in
      List.iter
        (fun (label, read) ->
          ignore (read ());
          check int (label ^ " leaves the descriptor count unchanged") before (open_descriptors ()))
        reads)

(* A boxed run (observe, guest_local) lays its scratch over the payload env the
   dispatcher built: HOME and TMPDIR are the scratch whatever the file says,
   and the file's other names still reach the payload. *)
let test_boxed_run_scratch_is_laid_over_the_endpoint_env () =
  with_tmp_tree (fun root ->
      let env_file = Filename.concat root "shim.env" in
      let config =
        match
          Exec_shim.parse_config (Printf.sprintf "remote_root=%s\nenv_file=%s\n" root env_file)
        with
        | Ok config -> config
        | Error e -> fail ("config fixture rejected: " ^ e)
      in
      write_endpoint_file env_file "VIRTUAL_ENV=/opt/venv\nHOME=/root\nTMPDIR=/var/tmp\n";
      match Exec_shim.payload_env ~config ~base_env:shim_env ~request_env:[] with
      | Error e -> fail e
      | Ok env ->
        let scratch = "/tmp/masc-observe-1-abc" in
        let boxed = Exec_shim.scratch_env ~scratch env in
        check (option string) "HOME is the scratch, not the file's" (Some scratch)
          (List.assoc_opt "HOME" boxed);
        check (option string) "TMPDIR is the scratch, not the file's" (Some scratch)
          (List.assoc_opt "TMPDIR" boxed);
        check (option string) "a name the file declares survives the box" (Some "/opt/venv")
          (List.assoc_opt "VIRTUAL_ENV" boxed);
        check int "names stay unique"
          (List.length (List.sort_uniq compare (List.map fst boxed))) (List.length boxed))

(* The composition the dispatcher runs: the config names the file, the file is
   read, and its declarations sit between the base and the wire. *)
let test_payload_env_reads_the_configured_file () =
  with_tmp_tree (fun root ->
      let env_file = Filename.concat root "shim.env" in
      let config =
        match
          Exec_shim.parse_config
            (Printf.sprintf
               "remote_root=%s\npath=/opt/venv/bin:/usr/bin\nenv_allowlist=LANG\nenv_file=%s\n"
               root env_file)
        with
        | Ok config -> config
        | Error e -> fail ("config fixture rejected: " ^ e)
      in
      write_endpoint_file env_file "VIRTUAL_ENV=/opt/venv\nLANG=C.UTF-8\n";
      (match Exec_shim.payload_env ~config ~base_env:shim_env ~request_env:[ "LANG", "C" ] with
       | Error e -> fail e
       | Ok env ->
         check (option string) "declared in the file" (Some "/opt/venv")
           (List.assoc_opt "VIRTUAL_ENV" env);
         check (option string) "path= is the PATH" (Some "/opt/venv/bin:/usr/bin")
           (List.assoc_opt "PATH" env);
         check (option string) "the allowlisted wire value is laid over the file" (Some "C")
           (List.assoc_opt "LANG" env));
      write_endpoint_file env_file "PATH=/opt/venv/bin\n";
      match Exec_shim.payload_env ~config ~base_env:shim_env ~request_env:[] with
      | Ok _ -> fail "a malformed env_file must refuse the request"
      | Error e -> check bool "a malformed env_file is a config error" true (is_config_error e))

let test_jail_allows_root_itself () =
  with_tmp_tree (fun root ->
      match Exec_shim.check_cwd_jail ~root ~cwd:root with
      | Ok () -> ()
      | Error e -> fail e)

let test_jail_allows_descendant () =
  with_tmp_tree (fun root ->
      let cwd = Filename.concat root "sub" in
      match Exec_shim.check_cwd_jail ~root ~cwd with
      | Ok () -> ()
      | Error e -> fail e)

let test_jail_rejects_escape () =
  with_tmp_tree (fun root ->
      match Exec_shim.check_cwd_jail ~root ~cwd:(Filename.dirname root) with
      | Ok () -> fail "parent of remote_root must be rejected"
      | Error e ->
        check bool "named jail violation" true
          (contains Exec_shim.jail_error_code e))

(* The shape #31554 hit: one sshd, two Keepers, two roots. Before the request
   carried its own root the shim checked every call against one global value,
   so the second endpoint's own directory read as an escape from the first. *)
let test_request_root_inside_host_root_is_allowed () =
  with_tmp_tree (fun root ->
      let request_root = Filename.concat root "sub" in
      match Exec_shim.check_request_root_jail ~config_root:root ~request_root with
      | Ok () -> ()
      | Error e -> fail e)

let test_sibling_endpoint_root_is_not_an_escape () =
  with_tmp_tree (fun root ->
      let a = Filename.concat root "playground" in
      let b = Filename.concat root "playground-alpha" in
      Unix.mkdir a 0o755;
      Unix.mkdir b 0o755;
      (* Each endpoint declares its own root; the host allows both. *)
      (match Exec_shim.check_request_root_jail ~config_root:root ~request_root:b with
       | Error e -> fail ("sibling endpoint root rejected: " ^ e)
       | Ok () -> ());
      (* And a cwd is judged against the root that call asked for, not the
         other endpoint's. *)
      match Exec_shim.check_cwd_jail ~root:b ~cwd:b with
      | Ok () -> ()
      | Error e -> fail ("cwd in its own root rejected: " ^ e))

(* A request must not be able to widen its own jail: the config stays the
   upper bound. *)
let test_request_root_outside_host_root_is_rejected () =
  with_tmp_tree (fun root ->
      let outside = Filename.dirname root in
      match
        Exec_shim.check_request_root_jail ~config_root:root ~request_root:outside
      with
      | Ok () -> fail "a request widened its own jail past the host's root"
      | Error e ->
        check bool "named jail violation" true
          (contains Exec_shim.jail_error_code e))

(* The composition, at the point the bug lived. Testing the two halves apart
   from each other is what let #31554 sit here: both passed while the
   dispatcher still judged the cwd against the host's single root. *)
let request_for ~remote_root ~cwd =
  { Exec_ssh_protocol.v = Exec_ssh_protocol.newest
  ; argv = [ "/bin/true" ]
  ; env = []
  ; cwd
  ; remote_root
  ; timeout_sec = 1.0
  ; stdin_len = 0L
  ; mode = Exec_ssh_protocol.Effect
  }

let config_for root =
  match
    Exec_shim.parse_config (Printf.sprintf "remote_root=%s\nenv_allowlist=\n" root)
  with
  | Ok config -> config
  | Error e -> fail ("config fixture rejected: " ^ e)

let test_dispatch_uses_the_request_root_not_the_host_root () =
  with_tmp_tree (fun root ->
      let mine = Filename.concat root "playground-alpha" in
      Unix.mkdir mine 0o755;
      let config = config_for root in
      let request = request_for ~remote_root:mine ~cwd:mine in
      match Exec_shim.jail_for_request ~config ~request with
      | Ok () -> ()
      | Error e -> fail ("a second endpoint's own root read as an escape: " ^ e))

let test_dispatch_rejects_a_cwd_outside_the_request_root () =
  with_tmp_tree (fun root ->
      let mine = Filename.concat root "playground-alpha" in
      let theirs = Filename.concat root "playground-delta" in
      Unix.mkdir mine 0o755;
      Unix.mkdir theirs 0o755;
      let config = config_for root in
      (* Both roots are inside the host's, so only the cwd check can refuse
         this: one endpoint must not reach into another's directory. *)
      let request = request_for ~remote_root:mine ~cwd:theirs in
      match Exec_shim.jail_for_request ~config ~request with
      | Ok () -> fail "one endpoint reached into another endpoint's root"
      | Error e ->
        check bool "named jail violation" true
          (contains Exec_shim.jail_error_code e))

let test_dispatch_rejects_a_request_root_outside_the_host_root () =
  with_tmp_tree (fun root ->
      let outside = Filename.dirname root in
      let config = config_for root in
      let request = request_for ~remote_root:outside ~cwd:outside in
      match Exec_shim.jail_for_request ~config ~request with
      | Ok () -> fail "a request widened its own jail past the host's root"
      | Error e ->
        check bool "named jail violation" true
          (contains Exec_shim.jail_error_code e))

let test_jail_rejects_dotdot_escape () =
  with_tmp_tree (fun root ->
      let cwd = Filename.concat root "sub/../.." in
      match Exec_shim.check_cwd_jail ~root ~cwd with
      | Ok () -> fail ".. escape must be rejected after normalization"
      | Error e ->
        check bool "named jail violation" true
          (contains Exec_shim.jail_error_code e))

let test_jail_rejects_missing_cwd () =
  with_tmp_tree (fun root ->
      let cwd = Filename.concat root "does-not-exist" in
      match Exec_shim.check_cwd_jail ~root ~cwd with
      | Ok () -> fail "nonexistent cwd must be rejected"
      | Error e ->
        check bool "named jail violation" true
          (contains Exec_shim.jail_error_code e))

(* {1 nonblocking drain helper} *)

let test_drain_fd () =
  let (r, w) = Unix.pipe () in
  Unix.set_nonblock r;
  let buf = Buffer.create 16 in
  (match Exec_shim.drain_fd r buf with
   | Exec_shim.Drain_again -> ()
   | _ -> fail "empty pipe must report Drain_again");
  ignore (Unix.write_substring w "abc" 0 3);
  (match Exec_shim.drain_fd r buf with
   | Exec_shim.Drain_bytes n -> check int "three bytes drained" 3 n
   | _ -> fail "expected Drain_bytes");
  check string "drained content" "abc" (Buffer.contents buf);
  Unix.close w;
  (match Exec_shim.drain_fd r buf with
   | Exec_shim.Drain_eof -> ()
   | _ -> fail "closed pipe must report Drain_eof");
  Unix.close r

(* {1 probe} *)

let test_probe_identity () =
  let p = Exec_shim.probe () in
  let protocol_version = string_of_int Exec_ssh_protocol.protocol_version in
  check string "name" "masc-exec-shim" p.Exec_ssh_protocol.name;
  check string "version" (protocol_version ^ ".0.0") p.Exec_ssh_protocol.version;
  check (list string)
    "capabilities say exactly whether this host can box a payload and \
     whether it accepts a seccomp listener (task-1568)"
    ((if Exec_shim.observe_supported () then [ Exec_ssh_protocol.observe_capability ] else [])
     @ (if Exec_shim.user_notif_supported ()
        then [ Exec_ssh_protocol.user_notif_capability ]
        else []))
    p.Exec_ssh_protocol.capabilities;
  match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe p) with
  | Error e -> fail e
  | Ok p' ->
    check (result int string) "the probe names the wire protocol this build speaks"
      (Ok Exec_ssh_protocol.protocol_version)
      (Result.map Exec_ssh_protocol.int_of_major (Exec_ssh_protocol.major_of_probe p'))

let test_child_boundary_acknowledgements () =
  let open Exec_ssh_protocol in
  List.iter (fun (ack, expected) ->
    check bool ("child acknowledgement " ^ String.escaped ack) true
      (Exec_shim.child_boundary_of_ack ack = expected))
    ["A", Sandbox_applied; "AE", Exec_failed; "S", Setup_failed;
     "N", Refused_socket; "W", Refused_write;
     "", Child_ack_unavailable; "E", Child_ack_unavailable;
     "AA", Child_ack_unavailable; "AEX", Child_ack_unavailable]

(* Review 5192723206: the "N"/"W" path once went dead because the raw
   8-byte buffer never equalled the bare tag. Pin the emission mapping
   itself -- the C stub's fixed-size buffer with NUL padding -- so the
   path cannot go dead again without a red test.

   Review 5195604213 (bonus, non-blocking): nothing ties this decoder's
   "socket"/"write" literals to the C stub that writes them
   ("lib/exec_shim/observe_stub.c", where [refusing_rule] is assigned).
   If the C side's spelling ever drifts, this test still passes on its
   own OCaml-side literals while the real mismatch only shows up as a
   [Failure] on whatever host first hits the machine's actual refusal --
   loud, but in production, not in CI. Quoting the C file's path here
   (the repo's edited-test-file selector matches on the quoted string)
   at least routes an edit to that file through this suite, so a
   reviewer sees these two spellings side by side instead of trusting
   they still agree. *)
let test_refusal_of_rule_bytes () =
  let padded s =
    let b = Bytes.make 8 '\000' in
    Bytes.blit_string s 0 b 0 (String.length s);
    b
  in
  let expect name rule expected =
    match Exec_shim.refusal_of_rule_bytes (padded rule) with
    | exn -> check bool name true (exn = expected)
  in
  expect "socket rule -> Sandbox_refused_socket" "socket"
    Exec_shim.Sandbox_refused_socket;
  expect "write rule -> Sandbox_refused_write" "write"
    Exec_shim.Sandbox_refused_write;
  (* A full 8-byte name (no padding) must still match by content. *)
  let full = Bytes.of_string "socket\000\000" in
  check bool "socket with two NULs still matches" true
    (Exec_shim.refusal_of_rule_bytes full = Exec_shim.Sandbox_refused_socket);
  (* An unrecognized rule is a loud failure, never a silent allow. *)
  (match Exec_shim.refusal_of_rule_bytes (padded "other") with
   | exception Failure _ -> ()
   | exn ->
     failf "unknown rule should raise Failure, got %s"
       (Printexc.to_string exn))

(* {1 program lookup}

   Unix.execvpe searches the shim process's PATH, not the payload PATH it is
   handed, so a tool living only in a [path=] directory was never found (a
   Terminal-Bench task image with /opt/conda/bin in its PATH, reached over
   remote_ssh, whose sshd session PATH has no such entry). *)

let write_file path ~perm =
  let oc = open_out path in
  output_string oc "#!/bin/sh\nexit 0\n";
  close_out oc;
  Unix.chmod path perm

let test_program_with_a_slash_is_executed_as_named () =
  check (option string) "a path is not searched"
    (Some "/opt/conda/bin/python")
    (Exec_shim.resolve_program ~payload_path:[ "/usr/bin" ]
       ~is_executable:(fun _ -> false) "/opt/conda/bin/python")

let test_program_is_found_in_the_first_payload_directory_holding_it () =
  let present = [ "/opt/venv/bin/python"; "/usr/bin/python" ] in
  check (option string) "the payload path order decides"
    (Some "/opt/venv/bin/python")
    (Exec_shim.resolve_program
       ~payload_path:[ "/opt/conda/bin"; "/opt/venv/bin"; "/usr/bin" ]
       ~is_executable:(fun candidate -> List.mem candidate present) "python")

let test_program_absent_from_the_payload_path_is_not_found () =
  check (option string) "no fallback to any other PATH" None
    (Exec_shim.resolve_program ~payload_path:[ "/opt/conda/bin" ]
       ~is_executable:(fun _ -> false) "python")

let test_lookup_reads_the_filesystem_of_the_payload_path () =
  with_tmp_tree (fun root ->
      let tools = Filename.concat root "tools" in
      Unix.mkdir tools 0o755;
      write_file (Filename.concat tools "masc_probe_tool") ~perm:0o755;
      write_file (Filename.concat tools "not_executable") ~perm:0o644;
      Unix.mkdir (Filename.concat tools "a_directory") 0o755;
      let resolve = Exec_shim.resolve_program ~payload_path:[ root; tools ]
          ~is_executable:Exec_shim.is_executable_file in
      check (option string) "an executable file in a later directory"
        (Some (Filename.concat tools "masc_probe_tool")) (resolve "masc_probe_tool");
      check (option string) "a file without execute permission" None
        (resolve "not_executable");
      check (option string) "a directory" None (resolve "a_directory"))

let () =
  run "exec shim"
    [ "program lookup",
      [ test_case "a program with a slash is executed as named" `Quick
          test_program_with_a_slash_is_executed_as_named
      ; test_case "the first payload directory holding it wins" `Quick
          test_program_is_found_in_the_first_payload_directory_holding_it
      ; test_case "absent from the payload path is not found" `Quick
          test_program_absent_from_the_payload_path_is_not_found
      ; test_case "lookup reads the filesystem" `Quick
          test_lookup_reads_the_filesystem_of_the_payload_path ]
    ; "env", [ test_case "minimal base env" `Quick test_minimal_base_env
             ; test_case "base env defaults" `Quick test_base_env_defaults
             ; test_case "allowlist overlay survives" `Quick test_allowlist_overlay_survives
             ; test_case "runtime identity env survives an empty allowlist" `Quick
                 test_runtime_identity_env_survives_empty_allowlist
             ; test_case "denylist beats allowlist" `Quick test_denylist_beats_allowlist
             ; test_case "denylist names" `Quick test_denylist_names
             ; test_case "denylist predicate" `Quick test_denylisted_predicate
             ; test_case "endpoint env overlays the base" `Quick
                 test_endpoint_env_overlays_the_base
             ; test_case "wire meets the endpoint env" `Quick test_wire_meets_the_endpoint_env ]
    ; "env file", [ test_case "declares values verbatim" `Quick
                      test_env_file_declares_values_verbatim
                  ; test_case "CRLF lines" `Quick test_env_file_crlf_lines
                  ; test_case "rejects" `Quick test_env_file_rejects
                  ; test_case "errors name the line, not its text" `Quick
                      test_env_file_error_names_the_line_not_its_text
                  ; test_case "read" `Quick test_read_env_file
                  ; test_case "owner and mode rule" `Quick test_endpoint_file_owner_and_mode_rule
                  ; test_case "reads only a regular file" `Quick
                      test_read_env_file_reads_only_a_regular_file
                  ; test_case "refuses a file others may write" `Quick
                      test_read_env_file_refuses_a_file_others_may_write
                  ; test_case "a config file others may write is refused" `Quick
                      test_read_config_file_refuses_a_file_others_may_write
                  ; test_case "reads leave no descriptor open" `Quick
                      test_endpoint_file_reads_leave_no_descriptor_open
                  ; test_case "payload env reads the configured file" `Quick
                      test_payload_env_reads_the_configured_file
                  ; test_case "a boxed run's scratch is laid over it" `Quick
                      test_boxed_run_scratch_is_laid_over_the_endpoint_env ]
    ; "kill policy", [ test_case "on eof" `Quick test_kill_policy_on_eof
                     ; test_case "on timeout" `Quick test_kill_policy_on_timeout
                     ; test_case "on child exit" `Quick test_kill_policy_on_child_exit ]
    ; "trailer", [ test_case "exit status" `Quick test_trailer_of_status_exit
                 ; test_case "signal + timeout" `Quick test_trailer_of_status_signal_timeout
                 ; test_case "host signal numbers" `Quick test_host_signal_number ]
    ; "config", [ test_case "ok" `Quick test_parse_config_ok
                ; test_case "requires remote_root" `Quick test_parse_config_requires_root
                ; test_case "rejects relative root" `Quick test_parse_config_rejects_relative_root
                ; test_case "rejects unknown key" `Quick test_parse_config_rejects_unknown_key
                ; test_case "errors print no file text" `Quick
                    test_parse_config_errors_print_no_file_text
                ; test_case "path entries" `Quick test_parse_config_path_ok
                ; test_case "rejects a bad path" `Quick test_parse_config_rejects_bad_path
                ; test_case "env_file" `Quick test_parse_config_env_file
                ; test_case "synthesize_env takes the config path" `Quick
                    test_synthesize_env_takes_config_path ]
    ; "jail", [ test_case "allows root itself" `Quick test_jail_allows_root_itself
              ; test_case "allows descendant" `Quick test_jail_allows_descendant
              ; test_case "rejects escape" `Quick test_jail_rejects_escape
              ; test_case "rejects dotdot escape" `Quick test_jail_rejects_dotdot_escape
              ; test_case "request root inside the host root is allowed" `Quick
                  test_request_root_inside_host_root_is_allowed
              ; test_case "a sibling endpoint root is not an escape" `Quick
                  test_sibling_endpoint_root_is_not_an_escape
              ; test_case "request root outside the host root is rejected" `Quick
                  test_request_root_outside_host_root_is_rejected
              ; test_case "dispatch uses the request root" `Quick
                  test_dispatch_uses_the_request_root_not_the_host_root
              ; test_case "dispatch rejects a cwd outside the request root" `Quick
                  test_dispatch_rejects_a_cwd_outside_the_request_root
              ; test_case "dispatch rejects a request root outside the host root" `Quick
                  test_dispatch_rejects_a_request_root_outside_the_host_root
              ; test_case "rejects missing cwd" `Quick test_jail_rejects_missing_cwd ]
    ; "io", [ test_case "drain_fd" `Quick test_drain_fd ]
    ; "probe", [ test_case "identity" `Quick test_probe_identity ]
    ; "box", [ test_case "child-owned boundary acknowledgement" `Quick
                 test_child_boundary_acknowledgements
             ; test_case "refusal rule emission mapping" `Quick
                 test_refusal_of_rule_bytes
             ; test_case "plan for mode" `Quick test_plan_for_mode
             ; test_case "scratch env" `Quick test_scratch_env
             ; test_case "scratch_root config" `Quick test_parse_config_scratch_root
             ; test_case "support is consistent" `Quick test_observe_support_is_consistent
             ; test_case "user_notif support is consistent" `Quick
                 test_user_notif_support_is_consistent ] ]
