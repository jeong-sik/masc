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
      write_all Unix.stdout
        {|{"name":"masc-exec-shim","version":"1.0.0","capabilities":[]}|};
      exit 0
    | _ ->
      write_all Unix.stdout
        {|{"name":"masc-exec-shim","version":"2.0.0","capabilities":[]}|};
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
        { v = Exec_ssh_protocol.protocol_version
        ; exit = Some exit
        ; signal = None
        ; timed_out = false
        ; shim_error = None
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
    | "test" :: _ -> write_all Unix.stderr (trailer 0)
    | "df" :: _ ->
      let available = if String.equal mode "disk-low" then 1 else 2_097_152 in
      write_all Unix.stdout
        (Printf.sprintf
           "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 4000000 10 %d 1%% /srv\n"
           available);
      write_all Unix.stderr (trailer 0)
    | "env" :: _ when String.equal mode "gh-missing" ->
      write_all Unix.stderr ("not logged in\n" ^ trailer 1)
    | "env" :: _ -> write_all Unix.stderr (trailer 0)
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

let make_state ~base_path ~ssh_bin =
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
  Keeper_sandbox_ssh.For_testing.clear_preflight_cache ();
  check (result unit string) "first ready" (Ok ())
    (Keeper_sandbox_ssh.check_preflight state);
  check int "seven probes" 7 (invocation_count count_path);
  check (result unit string) "cached ready" (Ok ())
    (Keeper_sandbox_ssh.check_preflight state);
  check int "cache avoided respawn" 7 (invocation_count count_path);
  check (result unit string) "forced ready" (Ok ())
    (Keeper_sandbox_ssh.check_preflight ~force:true state);
  check int "force respawned" 14 (invocation_count count_path)
;;

let test_zero_ttl_rechecks () =
  with_eio @@ fun () ->
  with_env "MASC_KEEPER_SSH_PREFLIGHT_TTL_SEC" "0" @@ fun () ->
  let base_path = temp_dir () in
  let ssh_bin, count_path = make_stub ~dir:base_path ~mode:"ttl-zero" in
  let state = make_state ~base_path ~ssh_bin in
  Keeper_sandbox_ssh.For_testing.clear_preflight_cache ();
  check (result unit string) "first ready" (Ok ())
    (Keeper_sandbox_ssh.check_preflight state);
  check (result unit string) "second ready" (Ok ())
    (Keeper_sandbox_ssh.check_preflight state);
  check int "zero TTL respawned every probe" 14 (invocation_count count_path)
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
           (Keeper_sandbox_ssh.check_preflight ~force:true state)))
    [ "unreachable", "remote_ssh_endpoint_unreachable:"
    ; "skew", "remote_shim_version_skew:"
    ; "rg-missing", "remote_ripgrep_unavailable:"
    ; "disk-low", "remote_ssh_disk_low:"
    ; "gh-missing", "remote_github_identity_missing:"
    ]
;;

let () =
  if Array.length Sys.argv > 1 && String.equal Sys.argv.(1) "--preflight-stub"
  then stub_main ()
  else
    run "keeper_ssh_preflight"
      [ ( "preflight"
        , [ test_case "ready TTL + force" `Quick test_ready_ttl_and_force
          ; test_case "zero TTL rechecks" `Quick test_zero_ttl_rechecks
          ; test_case "named failures" `Quick test_named_failures
          ] )
      ]
