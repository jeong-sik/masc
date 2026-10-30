(** Interactive provisioning for one SSH execution endpoint.

    Host-key material is never trusted until the operator retypes its
    out-of-band fingerprint. GitHub tokens cross only the pinned SSH channel
    on stdin and are retained locally solely in the redaction registry. *)

open Cmdliner
open Masc

open Result.Syntax

(* Interactive SSH children are waited on synchronously inside Eio's signal
   runtime. Resume only the interrupted syscall, never spawn or stream again. *)
let rec resume_syscall operation =
  try operation () with
  | Unix.Unix_error (Unix.EINTR, _, _) -> resume_syscall operation
;;

let read_all ic =
  let buffer = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match input ic chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | count ->
      Buffer.add_subbytes buffer chunk 0 count;
      loop ()
  in
  loop ()
;;

let status_error argv = function
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED code ->
    Error (Printf.sprintf "%s exited %d" (List.hd argv) code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
    Error (Printf.sprintf "%s received signal %d" (List.hd argv) signal)
;;

let protect_process f =
  try f () with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let close_fd_noerr fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()
;;

let run_inherited argv =
  match argv with
  | [] -> Error "empty process argv"
  | program :: _ ->
    protect_process @@ fun () ->
    let pid =
      Unix.create_process program (Array.of_list argv)
        Unix.stdin Unix.stdout Unix.stderr
    in
    status_error argv (snd (resume_syscall (fun () -> Unix.waitpid [] pid)))
;;

let run_capture_stdout argv =
  match argv with
  | [] -> Error "empty process argv"
  | program :: _ ->
    protect_process @@ fun () ->
    let read_fd, write_fd = Unix.pipe ~cloexec:true () in
    let pid =
      try
        Unix.create_process program (Array.of_list argv)
          Unix.stdin write_fd Unix.stderr
      with exn ->
        close_fd_noerr read_fd;
        close_fd_noerr write_fd;
        raise exn
    in
    Unix.close write_fd;
    let ic = Unix.in_channel_of_descr read_fd in
    let output = Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> read_all ic) in
    let* () = status_error argv (snd (resume_syscall (fun () -> Unix.waitpid [] pid))) in
    Ok output
;;

let copy_channel source output =
  let bytes = Bytes.create (64 * 1024) in
  let rec write_all offset remaining =
    if remaining > 0
    then
      let written = resume_syscall (fun () -> Unix.write output bytes offset remaining) in
      if written = 0 then raise End_of_file;
      write_all (offset + written) (remaining - written)
  in
  let rec loop () =
    match input source bytes 0 (Bytes.length bytes) with
    | 0 -> ()
    | count ->
      write_all 0 count;
      loop ()
  in
  loop ()
;;

let run_with_file_stdin argv path =
  match argv with
  | [] -> Error "empty process argv"
  | program :: _ ->
    protect_process @@ fun () ->
    let source = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr source) @@ fun () ->
    let read_fd, write_fd = Unix.pipe ~cloexec:true () in
    let pid =
      try
        Unix.create_process program (Array.of_list argv)
          read_fd Unix.stdout Unix.stderr
      with exn ->
        close_fd_noerr read_fd;
        close_fd_noerr write_fd;
        raise exn
    in
    Unix.close read_fd;
    let write_error =
      try
        copy_channel source write_fd;
        None
      with
      | End_of_file -> Some "write returned zero bytes"
      | Sys_error message -> Some message
      | Unix.Unix_error (error, operation, target) ->
        Some
          (Printf.sprintf "%s(%s): %s" operation target
             (Unix.error_message error))
    in
    Unix.close write_fd;
    let status = snd (resume_syscall (fun () -> Unix.waitpid [] pid)) in
    let* () = status_error argv status in
    match write_error with
    | None -> Ok ()
    | Some error -> Error (Printf.sprintf "cannot stream %s: %s" path error)
;;

let ensure_dir path =
  try
    Fs_compat.mkdir_p path;
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_DIR
    then Ok ()
    else Error (Printf.sprintf "not a directory: %s" path)
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let ensure_dir_0700 path =
  let* () = ensure_dir path in
  try
    Unix.chmod path 0o700;
    Ok ()
  with
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let write_atomic ~mode path content =
  let* () = ensure_dir (Filename.dirname path) in
  let temp = Printf.sprintf "%s.tmp.%d" path (Unix.getpid ()) in
  try
    let fd =
      Unix.openfile temp [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] mode
    in
    let oc = Unix.out_channel_of_descr fd in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        output_string oc content;
        flush oc;
        Unix.fsync fd);
    Unix.chmod temp mode;
    Unix.rename temp path;
    Ok ()
  with
  | Sys_error message ->
    (try Sys.remove temp with Sys_error _ -> ());
    Error message
  | Unix.Unix_error (error, operation, target) ->
    (try Sys.remove temp with Sys_error _ -> ());
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let write_existing_private path content =
  try
    let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
    let oc = Unix.out_channel_of_descr fd in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        output_string oc content;
        flush oc;
        Unix.fsync fd);
    Unix.chmod path 0o600;
    Ok ()
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let read_regular_file path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind <> Unix.S_REG
    then Error (Printf.sprintf "not a regular file: %s" path)
    else
      let ic = open_in_bin path in
      Ok (Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> read_all ic))
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let path_exists path =
  match Unix.lstat path with
  | _ -> true
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
;;

let require_regular_file path =
  try
    let stat = Unix.lstat path in
    if stat.Unix.st_kind = Unix.S_REG
    then Ok ()
    else Error (Printf.sprintf "not a regular file: %s" path)
  with
  | Unix.Unix_error (error, operation, target) ->
    Error
      (Printf.sprintf "%s(%s): %s" operation target
         (Unix.error_message error))
;;

let shell_quote value =
  "'" ^ String.concat "'\\''" (String.split_on_char '\'' value) ^ "'"
;;

let replace_remote_command ssh argv_command =
  match List.rev (Keeper_sandbox_remote.transport_argv ssh) with
  | _fixed :: rest -> List.rev (argv_command :: rest)
  | [] -> [ "ssh"; argv_command ]
;;

let remote_target (endpoint : Exec_ssh_endpoint.t) =
  endpoint.user ^ "@" ^ endpoint.host
;;

let pinned_ssh ssh command = replace_remote_command ssh command

let ensure_keypair endpoint identity_file =
  let public_file = identity_file ^ ".pub" in
  let private_exists = path_exists identity_file in
  let public_exists = path_exists public_file in
  if private_exists <> public_exists
  then
    Error
      (Printf.sprintf
         "dedicated SSH keypair is incomplete; expected both %s and %s"
         identity_file public_file)
  else if private_exists
  then
    let* () = require_regular_file identity_file in
    let* () = require_regular_file public_file in
    Unix.chmod identity_file 0o600;
    Ok public_file
  else
    let* () = ensure_dir_0700 (Filename.dirname identity_file) in
    let* () =
      run_inherited
        [ "ssh-keygen"; "-q"; "-t"; "ed25519"; "-N"; ""; "-C"
        ; "masc:" ^ endpoint.Exec_ssh_endpoint.name; "-f"; identity_file
        ]
    in
    Unix.chmod identity_file 0o600;
    Ok public_file
;;

let host_key_scan endpoint =
  run_capture_stdout
    [ "ssh-keyscan"; "-T"; string_of_int endpoint.Exec_ssh_endpoint.connect_timeout_sec
    ; "-p"; string_of_int endpoint.port; "-t"; "ed25519"; endpoint.host
    ]
;;

let fingerprints_of_scan scan =
  let temp = Filename.temp_file "masc-ssh-hostkey-" ".pub" in
  let result =
    Fun.protect
      ~finally:(fun () -> try Sys.remove temp with Sys_error _ -> ())
    @@ fun () ->
    let* () = write_existing_private temp scan in
    run_capture_stdout [ "ssh-keygen"; "-E"; "sha256"; "-lf"; temp ]
  in
  result
;;

let fingerprint_tokens output =
  output
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
    match String.split_on_char ' ' (String.trim line) with
    | _bits :: fingerprint :: _ -> Some fingerprint
    | _ -> None)
;;

let confirm_host_key endpoint scan =
  let* fingerprints = fingerprints_of_scan scan in
  let tokens = fingerprint_tokens fingerprints in
  match tokens with
  | [ expected ] ->
    Printf.printf
      "Endpoint %s (%s:%d) ED25519 host-key fingerprint:\n%s\n\nVerify it out-of-band, then retype exactly: %!"
      endpoint.Exec_ssh_endpoint.name endpoint.host endpoint.port expected;
    (* [read_line] raises [End_of_file] on a closed stdin, and this function
       answers the other two cases with a string. A script, a CI job or an
       agent calling this with no terminal attached got that exception and an
       OCaml backtrace instead, which reads as a broken tool rather than as
       "run this where a person can read the fingerprint". *)
    (match In_channel.input_line In_channel.stdin with
     | None -> Error "remote_ssh_host_key_confirmation_needs_a_terminal"
     | Some entered ->
       if String.equal (String.trim entered) expected
       then Ok ()
       else Error "remote_ssh_host_key_confirmation_mismatch")
  | [] -> Error "ssh-keyscan returned no parseable ED25519 fingerprint"
  | _ -> Error "ssh-keyscan returned multiple ED25519 fingerprints"
;;

let install_known_hosts ~replace endpoint path scan =
  let* () = confirm_host_key endpoint scan in
  let* current =
    if path_exists path then read_regular_file path |> Result.map Option.some
    else Ok None
  in
  match current with
  | Some value when String.equal value scan -> Ok ()
  | Some _ when not replace ->
    Error
      (Printf.sprintf
         "known_hosts entry differs at %s; verify rotation and rerun with --replace-host-key"
         path)
  | Some _ | None -> write_atomic ~mode:0o600 path scan
;;

let authorize_key endpoint ~known_hosts_file public_file =
  run_inherited
    [ "ssh-copy-id"; "-i"; public_file; "-p"; string_of_int endpoint.Exec_ssh_endpoint.port
    ; "-F"; "none"; "-o"; "ForwardAgent=no"; "-o"
    ; "StrictHostKeyChecking=yes"; "-o"
    ; "UserKnownHostsFile=" ^ known_hosts_file; "-o"; "GlobalKnownHostsFile=none"
    ; remote_target endpoint
    ]
;;

let endpoint_shim_config ssh (endpoint : Exec_ssh_endpoint.t) =
  let default = "remote_root=" ^ endpoint.remote_root ^ "\n" in
  let* content =
    run_capture_stdout
      (pinned_ssh ssh
         ("if test -e /etc/masc-exec-shim.conf || test -L /etc/masc-exec-shim.conf; then "
          ^ "test -f /etc/masc-exec-shim.conf && test ! -L /etc/masc-exec-shim.conf "
          ^ "&& cat /etc/masc-exec-shim.conf; else printf %s "
          ^ shell_quote default ^ "; fi"))
  in
  let* config = Exec_shim.parse_config content in
  Ok
    (Exec_shim.render_config
       { config with remote_root = endpoint.remote_root
       ; env_allowlist = endpoint.env_allowlist })
;;

(* Resolve each directory through a no-follow descriptor before changing it.
   A Keeper can own its workspace, so a path check followed by install/chown
   would let a renamed symlink redirect the privileged operation. *)
let prepare_directory_script = {|
import os
import pwd
import sys

try:
    path = sys.argv[1]
    mode = int(sys.argv[2], 8)
    owner = pwd.getpwnam(sys.argv[3]).pw_uid if len(sys.argv) == 4 else None
    parts = path.split("/")
    if not os.path.isabs(path) or any(part in (".", "..") for part in parts):
        raise ValueError("directory must be an absolute path without dot segments")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    directory = os.open("/", flags)
    try:
        for part in parts:
            if not part:
                continue
            try:
                child = os.open(part, flags, dir_fd=directory)
            except FileNotFoundError:
                try:
                    os.mkdir(part, 0o755, dir_fd=directory)
                except FileExistsError:
                    pass
                child = os.open(part, flags, dir_fd=directory)
            os.close(directory)
            directory = child
        os.fchmod(directory, mode)
        if owner is not None:
            os.fchown(directory, owner, -1)
    finally:
        os.close(directory)
except (OSError, KeyError, ValueError) as error:
    print("remote_ssh_directory_prepare_failed:", error, file=sys.stderr)
    sys.exit(1)
|}
;;

let prepare_directory_command ?owner ~path ~mode () =
  String.concat " "
    ([ "sudo"; "-n"; "python3"; "-c"; shell_quote prepare_directory_script
     ; shell_quote path; Printf.sprintf "%o" mode
     ]
     @ (match owner with None -> [] | Some user -> [ shell_quote user ]))
;;

let install_shim ssh endpoint shim_path =
  let* stat =
    try Ok (Unix.lstat shim_path) with
    | Unix.Unix_error (error, operation, target) ->
      Error
        (Printf.sprintf "%s(%s): %s" operation target
           (Unix.error_message error))
  in
  if stat.Unix.st_kind <> Unix.S_REG
  then Error (Printf.sprintf "shim artifact is not a regular file: %s" shim_path)
  else
    let* config = endpoint_shim_config ssh endpoint in
    let* () =
      run_inherited
        (pinned_ssh ssh
           (prepare_directory_command ~path:endpoint.remote_root ~mode:0o755 ()))
    in
    let remote_temp = Printf.sprintf "/tmp/masc-exec-shim.%d" (Unix.getpid ()) in
    let upload = "umask 077; cat > " ^ shell_quote remote_temp in
    let* () = run_with_file_stdin (pinned_ssh ssh upload) shim_path in
    let command =
      String.concat " && "
        [ "config_temp=$(sudo -n mktemp /etc/masc-exec-shim.conf.XXXXXX)"
        ; "trap 'sudo -n rm -f \"$config_temp\"' EXIT"
        ; "printf %s " ^ shell_quote config
          ^ " | sudo -n tee \"$config_temp\" >/dev/null"
        ; "sudo -n chmod 0644 \"$config_temp\""
        ; "sudo -n install -m 0755 " ^ shell_quote remote_temp
          ^ " /usr/local/bin/masc-exec-shim"
        ; "rm -f " ^ shell_quote remote_temp
        ; "sudo -n mv -f \"$config_temp\" /etc/masc-exec-shim.conf"
        ; "sudo -n install -d -m 0755 /usr/local/share/masc"
        ; "probe=$(masc-exec-shim --probe)"
        ; "printf '%s\\n' \"$probe\" | sudo -n tee /usr/local/share/masc/exec-shim.version >/dev/null"
        ]
    in
    run_inherited (pinned_ssh ssh command)
;;

let validate_keeper_name keeper =
  let keeper = String.trim keeper in
  let safe_keeper = Workspace_utils.safe_filename keeper in
  if keeper = "" || keeper = "." || keeper = ".."
     || not (String.equal keeper safe_keeper)
  then Error (Printf.sprintf "invalid keeper name for remote provisioning: %S" keeper)
  else Ok keeper
;;

let provision_keeper_workspace ssh (endpoint : Exec_ssh_endpoint.t) keeper =
  let keeper_root = Filename.concat endpoint.remote_root keeper in
  run_inherited
    (pinned_ssh ssh
       (prepare_directory_command ~owner:endpoint.user
          ~path:keeper_root ~mode:0o700 ()))
;;

let provision_keeper_identity ssh endpoint ~base_path (keeper, token_file) =
  let keeper_root = Filename.concat endpoint.Exec_ssh_endpoint.remote_root keeper in
  let gh_dir = Filename.concat keeper_root ".config/gh" in
  let* raw_token = read_regular_file token_file in
  let token =
    if String.ends_with ~suffix:"\r\n" raw_token
    then String.sub raw_token 0 (String.length raw_token - 2)
    else if String.ends_with ~suffix:"\n" raw_token
    then String.sub raw_token 0 (String.length raw_token - 1)
    else raw_token
  in
  if String.length token < 8
     || not (String.equal token (String.trim token))
     || String.contains token '\n'
     || String.contains token '\r'
  then Error (Printf.sprintf "invalid GitHub token file for keeper %s" keeper)
  else
    let prepare =
      String.concat " && "
        [ "mkdir -p " ^ shell_quote gh_dir
        ; "chmod 0700 " ^ shell_quote gh_dir
        ; "env GH_CONFIG_DIR=" ^ shell_quote gh_dir
          ^ " gh auth login --hostname github.com --with-token"
        ]
    in
    let temp = Filename.temp_file "masc-remote-gh-token-" ".stdin" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove temp with Sys_error _ -> ())
    @@ fun () ->
    let redaction_file =
      Keeper_secret_redaction.ssh_remote_token_file ~base_path ~keeper_name:keeper
    in
    let* () = ensure_dir_0700 (Filename.dirname redaction_file) in
    let* () = write_atomic ~mode:0o600 redaction_file (token ^ "\n") in
    let* () = write_existing_private temp (token ^ "\n") in
    run_with_file_stdin (pinned_ssh ssh prepare) temp
;;

let parse_keeper_token value =
  match String.index_opt value '=' with
  | Some separator when separator > 0 && separator < String.length value - 1 ->
    let keeper = String.sub value 0 separator |> String.trim in
    let path =
      String.sub value (separator + 1) (String.length value - separator - 1)
      |> String.trim
    in
    if keeper = "" || path = "" then Error value else Ok (keeper, path)
  | _ -> Error value
;;

let validate_endpoint_for_bootstrap (endpoint : Exec_ssh_endpoint.t) =
  let forbidden value = String.contains value '\n' || String.contains value '\r' in
  if forbidden endpoint.remote_root
  then Error "remote_root must not contain a newline"
  else
    match
      List.find_opt
        (fun name -> forbidden name || String.contains name ',')
        endpoint.env_allowlist
    with
    | Some name ->
      Error
        (Printf.sprintf
           "env_allowlist entry cannot be encoded in shim config: %S" name)
    | None -> Ok ()
;;

let run base_path endpoint_name shim_path replace_host_key keepers keeper_tokens =
  let base_path =
    match base_path with
    | Some path -> path
    | None -> Sys.getcwd ()
  in
  let result =
    let* endpoint =
      Keeper_sandbox_ssh.resolve_endpoint_name ~base_path ~name:endpoint_name
    in
    let* () = validate_endpoint_for_bootstrap endpoint in
    (* Validate all local declarations before writing keys or touching the host. *)
    let* keeper_tokens =
      List.fold_left
        (fun acc value ->
           let* parsed = acc in
           match parse_keeper_token value with
           | Error _ ->
             Error "--github-token-file must be KEEPER=PATH"
           | Ok (keeper, token_file) ->
             let* keeper = validate_keeper_name keeper in
             let* () = require_regular_file token_file in
             Ok ((keeper, token_file) :: parsed))
        (Ok []) keeper_tokens
      |> Result.map List.rev
    in
    let* keepers =
      List.fold_left
        (fun acc keeper ->
           let* names = acc in
           let* keeper = validate_keeper_name keeper in
           Ok (keeper :: names))
        (Ok (List.map fst keeper_tokens)) keepers
      |> Result.map (List.sort_uniq String.compare)
    in
    let identity_file =
      if Filename.is_relative endpoint.identity_file
      then Filename.concat base_path endpoint.identity_file
      else endpoint.identity_file
    in
    let known_hosts_file =
      if Filename.is_relative endpoint.known_hosts_file
      then Filename.concat base_path endpoint.known_hosts_file
      else endpoint.known_hosts_file
    in
    let* public_file = ensure_keypair endpoint identity_file in
    let* scan = host_key_scan endpoint in
    let* () = install_known_hosts ~replace:replace_host_key endpoint known_hosts_file scan in
    let* () = authorize_key endpoint ~known_hosts_file public_file in
    let* ssh =
      Keeper_sandbox_ssh.create ~base_path ~keeper_name:"bootstrap" ~endpoint ()
    in
    let* () = install_shim ssh endpoint shim_path in
    (* --probe alone does not load the shim configuration. Execute the framed
       endpoint check before reporting success or creating Keeper workspaces. *)
    let* () = Keeper_sandbox_remote.check_endpoint_preflight ssh in
    let* () =
      List.fold_left
        (fun acc keeper -> let* () = acc in provision_keeper_workspace ssh endpoint keeper)
        (Ok ()) keepers
    in
    let* () =
      List.fold_left
        (fun acc item -> let* () = acc in provision_keeper_identity ssh endpoint ~base_path item)
        (Ok ()) keeper_tokens
    in
    Printf.printf
      "SSH endpoint %s provisioned. shim=%s keepers=%d\n%!"
      endpoint.name shim_path (List.length keepers);
    Ok ()
  in
  match result with
  | Ok () -> `Ok ()
  | Error message -> `Error (false, message)
;;

let base_path =
  let doc = "Workspace base path containing .masc/config/runtime.toml." in
  Arg.(value & opt (some dir) None & info [ "base-path" ] ~docv:"PATH" ~doc)
;;

let endpoint =
  let doc = "Endpoint name under [exec.ssh.endpoints.<name>]." in
  Arg.(required & opt (some string) None & info [ "endpoint" ] ~docv:"NAME" ~doc)
;;

let shim =
  let doc = "Static Linux masc-exec-shim artifact." in
  Arg.(value & opt file "artifacts/masc-exec-shim" & info [ "shim" ] ~docv:"PATH" ~doc)
;;

let replace_host_key =
  let doc = "Replace a changed known_hosts entry after fingerprint confirmation." in
  Arg.(value & flag & info [ "replace-host-key" ] ~doc)
;;

let keeper_tokens =
  let doc =
    "Provision one keeper GitHub identity from a local token file. Repeat as KEEPER=PATH. Token bytes are sent on SSH stdin and registered locally only for redaction."
  in
  Arg.(value & opt_all string [] & info [ "github-token-file" ] ~docv:"KEEPER=PATH" ~doc)
;;

let keepers =
  let doc =
    "Prepare a Keeper workspace without a GitHub login. Repeat for each Keeper. A --github-token-file also prepares its named Keeper."
  in
  Arg.(value & opt_all string [] & info [ "keeper" ] ~docv:"NAME" ~doc)
;;

let command =
  let doc = "Provision a pinned MASC SSH execution endpoint." in
  let info = Cmd.info "masc-exec-ssh-bootstrap" ~doc in
  Cmd.v info
    Term.(ret (const run $ base_path $ endpoint $ shim $ replace_host_key $ keepers $ keeper_tokens))
;;

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let status =
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Process_eio.init
      ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock:(Eio.Stdenv.clock env);
    Cmd.eval command
  in
  exit status
