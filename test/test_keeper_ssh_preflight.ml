open Alcotest
open Masc

let write_all fd content =
  let bytes = Bytes.unsafe_of_string content in
  let rec loop offset =
    if offset < Bytes.length bytes
    then
      let wrote = Unix.write fd bytes offset (Bytes.length bytes - offset) in
      loop (offset + wrote)
  in
  loop 0
;;

let read_exact fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length
    then
      let got = Unix.read fd bytes offset (length - offset) in
      if got = 0 then failwith "preflight stub: truncated frame"
      else loop (offset + got)
  in
  loop 0;
  Bytes.unsafe_to_string bytes
;;

let read_file path =
  if not (Sys.file_exists path)
  then ""
  else
    let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
      really_input_string ic (in_channel_length ic))
;;

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc content)
;;

let increment path =
  let current = Option.value (int_of_string_opt (String.trim (read_file path))) ~default:0 in
  write_file path (string_of_int (current + 1))
;;

let stub_main () =
  let count_path = Sys.argv.(2) in
  let mode = Sys.argv.(3) in
  increment count_path;
  let last = Sys.argv.(Array.length Sys.argv - 1) in
  if String.equal last "masc-exec-shim --probe"
  then (
    match mode with
    | "unreachable" ->
      write_all Unix.stderr "connection refused";
      exit 255
    | "skew" ->
      (* One major past whatever this build speaks: the skew is the fact
         under test, not the number. (One behind is v2, which this build
         still speaks, so it would not be a skew.) *)
      write_all Unix.stdout
        (Printf.sprintf
           {|{"name":"masc-exec-shim","version":"%d.0.0","capabilities":[]}|}
           (Exec_ssh_protocol.protocol_version + 1));
      exit 0
    | _ ->
      (* The host's own major, read from the protocol rather than typed:
         #33372 moved it from 2 to 3 and a literal here turned every good
         probe into a skew. *)
      write_all Unix.stdout
        (Printf.sprintf
           {|{"name":"masc-exec-shim","version":"%d.0.0","capabilities":[]}|}
           Exec_ssh_protocol.protocol_version);
      exit 0)
  else (
    let header = read_exact Unix.stdin 8 in
    let body_len =
      Bytes.get_int64_be (Bytes.unsafe_of_string header) 0 |> Int64.to_int
    in
    let frame = header ^ read_exact Unix.stdin body_len in
    let request =
      match Exec_ssh_protocol.decode_request frame with
      | Ok (request, _) -> request
      | Error error -> failwith error
    in
    let trailer exit =
      Exec_ssh_protocol.render_trailer
        { v = Exec_ssh_protocol.newest
        ; exit = Some exit
        ; signal = None
        ; timed_out = false
        ; shim_error = None
        ; observed_syscalls = []
        }
    in
    match request.argv with
    | "git" :: _ ->
      write_all Unix.stdout "git version 2.50.0\n";
      write_all Unix.stderr (trailer 0)
    | "rg" :: _ when String.equal mode "rg-missing" ->
      write_all Unix.stderr ("rg unavailable\n" ^ trailer 127)
    | "rg" :: _ ->
      write_all Unix.stdout "ripgrep 14.1.1\n";
      write_all Unix.stderr (trailer 0)
    (* The identity step is conditional on the endpoint having a login at
       all, which the preflight reads as `test -s <gh config>/hosts.yml`. *)
    | [ "test"; "-s"; path ] when String.equal (Filename.basename path) "hosts.yml" ->
      write_all Unix.stderr
        (trailer (if String.equal mode "gh-unconfigured" then 1 else 0))
    | "test" :: _ -> write_all Unix.stderr (trailer 0)
    | "df" :: _ ->
      let available = if String.equal mode "disk-low" then 1 else 2_097_152 in
      write_all Unix.stdout
        (Printf.sprintf
           "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 4000000 10 %d 1%% /srv\n"
           available);
      write_all Unix.stderr (trailer 0)
    | "env" :: _
      when String.equal mode "gh-missing" || String.equal mode "gh-unconfigured" ->
      (* No hosts.yml means gh reports no login, exactly as in gh-missing.
         The two modes differ only in whether the endpoint was ever given
         one, which is what the preflight now asks first. A fixture where gh
         succeeds here would pass with or without that question. *)
      write_all Unix.stderr ("not logged in\n" ^ trailer 1)
    | "env" :: _ when String.equal mode "gh-blinded" ->
      write_all Unix.stderr
        ( "X Failed to log in to github.com account fixture: The token in \
           hosts.yml is invalid.\n"
        ^ trailer 1 )
    | "env" :: _ -> write_all Unix.stderr (trailer 0)
    | "curl" :: _ when String.equal mode "gh-missing" ->
      (* gh failed for a real identity reason: the API answers. *)
      write_all Unix.stderr (trailer 0)
    | "curl" :: _ ->
      (* gh failed with the endpoint off the network: DNS dies first. *)
      write_all Unix.stderr
        ("curl: (6) Could not resolve host: api.github.com\n" ^ trailer 6)
    | argv -> failwith ("unexpected preflight argv: " ^ String.concat " " argv));
  exit 0
;;

let shell_quote s = "'" ^ String.concat "'\\''" (String.split_on_char '\'' s) ^ "'"

let temp_dir () =
  let path = Filename.temp_file "masc-ssh-preflight-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path
;;

let make_stub ~dir ~mode =
  let count_path = Filename.concat dir (mode ^ ".count") in
  let script_path = Filename.concat dir (mode ^ ".ssh") in
  write_file script_path
    (Printf.sprintf "#!/bin/sh\nexec %s --preflight-stub %s %s \"$@\"\n"
       (shell_quote Sys.executable_name)
       (shell_quote count_path)
       (shell_quote mode));
  Unix.chmod script_path 0o755;
  script_path, count_path
;;

let endpoint : Exec_ssh_endpoint.t =
  { name = "fixture"
  ; host = "fixture.invalid"
  ; user = "masc"
  ; port = 22
  ; identity_file = ".masc/ssh/fixture.key"
  ; known_hosts_file = ".masc/ssh/known_hosts.d/fixture"
  ; remote_root = "/srv/masc/playground"
  ; connect_timeout_sec = 1
  ; max_concurrent_sessions = 2
  ; env_allowlist = []
  ; capabilities = []
  ; private_home = false
  ; allowed_paths = []
  }
;;

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value previous ~default:""))
    f
;;

let with_eio f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Process_eio.init
    ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Fun.protect ~finally:Process_eio.reset_for_testing f
;;

let state_for_endpoint ~base_path ~ssh_bin endpoint =
  match
    Keeper_sandbox_ssh.create ~ssh_bin ~base_path ~keeper_name:"keeper-a"
      ~endpoint ()
  with
  | Ok state -> state
  | Error error -> fail error
;;

let invocation_count path =
  Option.value (int_of_string_opt (String.trim (read_file path))) ~default:0
;;

let make_state ~base_path ~ssh_bin = state_for_endpoint ~base_path ~ssh_bin endpoint
;;

let contains_prefix prefix = function
  | Ok () -> false
  | Error error -> String.starts_with ~prefix error
;;

let test_ready_ttl_and_force () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "60" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"ok" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  check (result unit string) "first ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight state);
  check int "eight probes" 8 (invocation_count count_path);
  check (result unit string) "cached ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight state);
  check int "cache avoided respawn" 8 (invocation_count count_path);
  check (result unit string) "forced ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight ~force:true state);
  check int "force respawned" 16 (invocation_count count_path)
;;

let test_reconfigured_endpoint_does_not_inherit_readiness () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "60" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"ok" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  check (result unit string) "original ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight state);
  List.iter
    (fun (label, declaration) ->
       let state = state_for_endpoint ~base_path ~ssh_bin declaration in
       let before = invocation_count count_path in
       check (result unit string) (label ^ " checked its own endpoint") (Ok ())
         (Keeper_sandbox_remote.check_preflight state);
       let after = invocation_count count_path in
       check bool (label ^ " ran new probes") true (after > before);
       check (result unit string) (label ^ " caches only its new result") (Ok ())
         (Keeper_sandbox_remote.check_preflight state);
       check int (label ^ " second read uses its own cache") after (invocation_count count_path))
    [ "host", { endpoint with host = "changed.invalid" }
    ; "root", { endpoint with remote_root = "/changed/root" }
    ; "key path", { endpoint with identity_file = "changed-key" }
    ; "host pin", { endpoint with known_hosts_file = "changed-hosts" }
    ; "allowlist", { endpoint with env_allowlist = [ "TERM" ] }
    ; "declared paths", { endpoint with allowed_paths = [ "/app" ] }
    ];
  let count = invocation_count count_path in
  check (result unit string) "original cache remains its own" (Ok ())
    (Keeper_sandbox_remote.check_preflight state);
  check int "other declarations do not invalidate original evidence" count (invocation_count count_path)
;;

let test_zero_ttl_rechecks () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"ttl-zero" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  check (result unit string) "first ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight state);
  check (result unit string) "second ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight state);
  check int "zero TTL respawned every probe" 16 (invocation_count count_path)
;;

let test_named_failures () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  List.iter
    (fun (mode, prefix) ->
      let base_path = temp_dir () in
      let ssh_bin, _ = make_stub ~dir:base_path ~mode in
      let state = make_state ~base_path ~ssh_bin in
      check bool mode true
        (contains_prefix prefix
           (Keeper_sandbox_remote.check_preflight ~force:true state)))
    [ "unreachable", "remote_ssh_endpoint_unreachable:"
    ; "skew", "remote_shim_version_skew:"
    ; "rg-missing", "remote_ripgrep_unavailable:"
    ; "disk-low", "remote_ssh_disk_low:"
    ; "gh-missing", "remote_github_identity_missing:"
    ; "gh-blinded", "remote_github_unreachable:"
    ]
;;

(* A host under the free-disk floor still answers a read. Calls that read
   (Read, Grep, a read authority, an Execute whose intent is Auto) are the
   ones that pass; the default stays the whole preflight. *)
let test_read_only_passes_a_host_under_the_floor () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, _ = make_stub ~dir:base_path ~mode:"disk-low" in
  let state = make_state ~base_path ~ssh_bin in
  check (result unit string) "a reader passes" (Ok ())
    (Keeper_sandbox_remote.check_preflight ~force:true
       ~access:Keeper_sandbox_remote.Read_only state);
  check bool "a writer is refused" true
    (contains_prefix "remote_ssh_disk_low:"
       (Keeper_sandbox_remote.check_preflight ~force:true
          ~access:Keeper_sandbox_remote.Read_write state));
  check bool "no access given is a writer" true
    (contains_prefix "remote_ssh_disk_low:"
       (Keeper_sandbox_remote.check_preflight ~force:true state))
;;

(* The floor is the only step a reader skips: each other failure still
   refuses it with the same named error. *)
let test_read_only_keeps_every_other_step () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  List.iter
    (fun (mode, prefix) ->
      let base_path = temp_dir () in
      let ssh_bin, _ = make_stub ~dir:base_path ~mode in
      let state = make_state ~base_path ~ssh_bin in
      check bool mode true
        (contains_prefix prefix
           (Keeper_sandbox_remote.check_preflight ~force:true
              ~access:Keeper_sandbox_remote.Read_only state)))
    [ "unreachable", "remote_ssh_endpoint_unreachable:"
    ; "skew", "remote_shim_version_skew:"
    ; "rg-missing", "remote_ripgrep_unavailable:"
    ; "gh-missing", "remote_github_identity_missing:"
    ; "gh-blinded", "remote_github_unreachable:"
    ]
;;

(* One pass fills the cache for both kinds of caller: a reader that found the
   host under the floor does not make the next writer probe it again. *)
let test_one_pass_serves_both_accesses () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "60" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"disk-low" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  check (result unit string) "reader" (Ok ())
    (Keeper_sandbox_remote.check_preflight
       ~access:Keeper_sandbox_remote.Read_only state);
  let probes = invocation_count count_path in
  check int "one pass probes every step" 8 probes;
  check bool "writer reads the same entry" true
    (contains_prefix "remote_ssh_disk_low:"
       (Keeper_sandbox_remote.check_preflight
          ~access:Keeper_sandbox_remote.Read_write state));
  check int "no second pass" probes (invocation_count count_path)
;;

(* A pass that let a reader through serves readers for the read TTL and
   writers for the refusal TTL. The refusal TTL is one second here and the read
   TTL an hour, so what each caller does after the sleep says which TTL it got. *)
let test_reader_keeps_a_ready_pass_longer_than_a_writer () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "1" @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_READ_TTL_SEC" "3600" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"ok" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  let check_as access = Keeper_sandbox_remote.check_preflight ~access state in
  check (result unit string) "reader ready" (Ok ())
    (check_as Keeper_sandbox_remote.Read_only);
  let probes = invocation_count count_path in
  check bool "the reader ran a pass" true (probes > 0);
  Unix.sleepf 1.2;
  check (result unit string) "reader after the refusal TTL" (Ok ())
    (check_as Keeper_sandbox_remote.Read_only);
  check int "reader reused the pass" probes (invocation_count count_path);
  check (result unit string) "writer after the refusal TTL" (Ok ())
    (check_as Keeper_sandbox_remote.Read_write);
  check bool "writer ran a new pass" true (invocation_count count_path > probes)
;;

(* A refusal is not given the read TTL: once the refusal TTL has passed, the
   next reader asks the host again, so a restored login is noticed. *)
let test_refused_reader_is_asked_again_after_the_refusal_ttl () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "1" @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_READ_TTL_SEC" "3600" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"gh-missing" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_remote.For_testing.clear_preflight_cache ();
  let reader () =
    Keeper_sandbox_remote.check_preflight
      ~access:Keeper_sandbox_remote.Read_only state
  in
  check bool "refused" true
    (contains_prefix "remote_github_identity_missing:" (reader ()));
  let probes = invocation_count count_path in
  Unix.sleepf 1.2;
  check bool "still refused" true
    (contains_prefix "remote_github_identity_missing:" (reader ()));
  check bool "asked the host again" true (invocation_count count_path > probes)
;;

let test_absent_github_login_is_not_a_blocker () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, _ = make_stub ~dir:base_path ~mode:"gh-unconfigured" in
  let state = make_state ~base_path ~ssh_bin in
  (* The endpoint has no hosts.yml and `gh auth status` would fail. Until
     #35412 that refused every tool call the keeper made, including work that
     never touches GitHub. An endpoint that was never given an identity is not
     an endpoint with a broken one. *)
  check (result unit string) "no login, still ready" (Ok ())
    (Keeper_sandbox_remote.check_preflight ~force:true state)
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--preflight-stub"
  then stub_main ()
  else
    run "keeper_ssh_preflight"
      [ ( "preflight"
        , [ test_case "ready TTL + force" `Quick test_ready_ttl_and_force
          ; test_case "reconfigured endpoint has independent readiness" `Quick
              test_reconfigured_endpoint_does_not_inherit_readiness
          ; test_case "zero TTL rechecks" `Quick test_zero_ttl_rechecks
          ; test_case "named failures" `Quick test_named_failures
          ; test_case "absent GitHub login" `Quick
              test_absent_github_login_is_not_a_blocker
          ; test_case "read-only passes a host under the floor" `Quick
              test_read_only_passes_a_host_under_the_floor
          ; test_case "read-only keeps every other step" `Quick
              test_read_only_keeps_every_other_step
          ; test_case "one pass serves both accesses" `Quick
              test_one_pass_serves_both_accesses
          ; test_case "reader keeps a ready pass longer than a writer" `Quick
              test_reader_keeps_a_ready_pass_longer_than_a_writer
          ; test_case "refused reader is asked again after the refusal TTL" `Quick
              test_refused_reader_is_asked_again_after_the_refusal_ttl
          ] )
      ]
