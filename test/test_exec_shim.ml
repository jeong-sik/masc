open Alcotest

(* Pure-core tests for the masc-exec-shim library (Phase 1 SSH remote
   execution lane, spec §4.2).  No real signals, no fork: the kill policy
   and status mapping are asserted as pure decisions. *)

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
  let env = Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:[] ~request_env:[] in
  check (option string) "PATH is the fixed minimal value"
    (Some Exec_shim.default_base_path) (List.assoc_opt "PATH" env);
  check (option string) "HOME from shim env" (Some "/home/dev") (List.assoc_opt "HOME" env);
  check (option string) "USER from shim env" (Some "dev") (List.assoc_opt "USER" env);
  check (option string) "TMPDIR from shim env" (Some "/scratch") (List.assoc_opt "TMPDIR" env);
  check int "base env is exactly PATH/HOME/USER/TMPDIR" 4 (List.length env)

let test_base_env_defaults () =
  let env = Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~base_env:[] ~allowlist:[] ~request_env:[] in
  check (option string) "HOME default" (Some "/tmp") (List.assoc_opt "HOME" env);
  check (option string) "USER default" (Some "masc") (List.assoc_opt "USER" env);
  check (option string) "TMPDIR default" (Some "/tmp") (List.assoc_opt "TMPDIR" env)

let test_allowlist_overlay_survives () =
  let env = Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:[ "FOO" ]
      ~request_env:[ ("FOO", "ok"); ("BAR", "not-allowlisted") ] in
  check (option string) "allowlisted FOO kept" (Some "ok") (List.assoc_opt "FOO" env);
  check (option string) "non-allowlisted BAR dropped" None (List.assoc_opt "BAR" env)

let test_runtime_identity_env_survives_empty_allowlist () =
  let env =
    Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:[]
      ~request_env:
        [ "GH_CONFIG_DIR", "/srv/masc/playground/keeper-a/.config/gh"
        ; "GIT_TERMINAL_PROMPT", "0"
        ; "LANG", "C"
        ]
  in
  check (option string) "runtime GitHub identity kept"
    (Some "/srv/masc/playground/keeper-a/.config/gh")
    (List.assoc_opt "GH_CONFIG_DIR" env);
  check (option string) "runtime prompt guard kept" (Some "0")
    (List.assoc_opt "GIT_TERMINAL_PROMPT" env);
  check (option string) "ordinary caller env still needs allowlisting" None
    (List.assoc_opt "LANG" env)

let test_denylist_beats_allowlist () =
  let env = Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~base_env:[]
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
  let env = Exec_shim.synthesize_env ~path:Exec_shim.default_base_path ~base_env:shim_env ~allowlist:(List.map fst wire)
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
  let t = Exec_shim.trailer_of_status ~timed_out:false (Unix.WEXITED 7) in
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
  let t = Exec_shim.trailer_of_status ~timed_out:true (Unix.WSIGNALED Sys.sigterm) in
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
    Exec_shim.synthesize_env ~path:"/home/opam/.opam/5.5/bin:/usr/bin"
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
  { Exec_ssh_protocol.v = Exec_ssh_protocol.protocol_version
  ; argv = [ "/bin/true" ]
  ; env = []
  ; cwd
  ; remote_root
  ; timeout_sec = 1.0
  ; stdin_len = 0L
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
  let p = Exec_shim.probe in
  let protocol_version = string_of_int Exec_ssh_protocol.protocol_version in
  check string "name" "masc-exec-shim" p.Exec_ssh_protocol.name;
  check string "version" (protocol_version ^ ".0.0") p.Exec_ssh_protocol.version;
  check (list string) "capabilities" [] p.Exec_ssh_protocol.capabilities;
  match Exec_ssh_protocol.parse_probe (Exec_ssh_protocol.render_probe p) with
  | Error e -> fail e
  | Ok p' ->
    check bool "major compatible with the wire protocol" true
      (Exec_ssh_protocol.probe_major_compatible ~want:protocol_version
         p'.Exec_ssh_protocol.version)

let () =
  run "exec shim"
    [ "env", [ test_case "minimal base env" `Quick test_minimal_base_env
             ; test_case "base env defaults" `Quick test_base_env_defaults
             ; test_case "allowlist overlay survives" `Quick test_allowlist_overlay_survives
             ; test_case "runtime identity env survives an empty allowlist" `Quick
                 test_runtime_identity_env_survives_empty_allowlist
             ; test_case "denylist beats allowlist" `Quick test_denylist_beats_allowlist
             ; test_case "denylist names" `Quick test_denylist_names
             ; test_case "denylist predicate" `Quick test_denylisted_predicate ]
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
                ; test_case "path entries" `Quick test_parse_config_path_ok
                ; test_case "rejects a bad path" `Quick test_parse_config_rejects_bad_path
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
    ; "probe", [ test_case "identity" `Quick test_probe_identity ] ]
