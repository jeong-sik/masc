open Alcotest

(* Exercise the actual pre-exec boundary in a disposable child. The external
   is the same one Exec_shim uses; the parent never enters the sandbox. *)
external restrict_self : string -> bool -> bool -> unit = "ocaml_shim_restrict_self"

let with_fd path flags f =
  let fd = Unix.openfile path flags 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)
;;

let assert_denied label expected operation =
  match operation () with
  | () -> fail (label ^ " unexpectedly succeeded")
  | exception Unix.Unix_error (actual, _, _) when actual = expected -> ()
;;

let test_observe_discard_without_persistent_effects () =
  check
    bool
    "CI kernel must support the actual Observe boundary"
    true
    (Exec_shim.observe_supported ());
  let root = Filename.temp_file "masc-observe-device-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let scratch = Filename.concat root "scratch" in
  let persistent = Filename.concat root "persistent" in
  let alias = Filename.concat root "persistent-link" in
  let created = Filename.concat root "new-file" in
  let scratch_file = Filename.concat scratch "scratch-output" in
  Unix.mkdir scratch 0o700;
  let sentinel = "persistent content must survive" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [ alias; persistent; created; scratch_file ];
      Unix.rmdir scratch;
      Unix.rmdir root)
    (fun () ->
       with_fd persistent [ Unix.O_CREAT; Unix.O_WRONLY ] (fun fd ->
         check
           int
           "fixture written"
           (String.length sentinel)
           (Unix.write_substring fd sentinel 0 (String.length sentinel)));
       Unix.symlink persistent alias;
       flush_all ();
       let pid = Unix.fork () in
       if pid = 0
       then (
         let status =
           try
             restrict_self scratch true true;
             with_fd "/dev/null" [ Unix.O_RDWR ] (fun fd ->
               let discarded = "ordinary observer output" in
               check
                 int
                 "discard device accepts output"
                 (String.length discarded)
                 (Unix.write_substring fd discarded 0 (String.length discarded));
               check int "discard device reads EOF" 0 (Unix.read fd (Bytes.create 1) 0 1));
             (* Shell redirection uses O_TRUNC as well as a writable open. *)
             let shell =
               Unix.create_process
                 "/bin/sh"
                 [| "sh"; "-c"; "printf discarded >/dev/null" |]
                 Unix.stdin
                 Unix.stdout
                 Unix.stderr
             in
             check
               bool
               "ordinary discard redirection works"
               true
               (snd (Unix.waitpid [] shell) = Unix.WEXITED 0);
             let diff_status right =
               let git = Unix.create_process "git"
                 [| "git"; "-C"; root; "diff"; "--no-index"; "--no-ext-diff";
                    "--no-textconv"; "--exit-code"; persistent; right |]
                 Unix.stdin Unix.stdout Unix.stderr in
               snd (Unix.waitpid [] git)
             in
             check bool "unchanged diff is payload exit zero" true
               (diff_status persistent = Unix.WEXITED 0);
             check bool "changed diff is payload exit one under the same Observe policy" true
               (diff_status "/dev/null" = Unix.WEXITED 1);
             List.iter
               (fun path ->
                  assert_denied "persistent write" Unix.EACCES (fun () ->
                    with_fd path [ Unix.O_WRONLY; Unix.O_TRUNC ] (fun _ -> ())))
               [ persistent; alias ];
             assert_denied "persistent create" Unix.EACCES (fun () ->
               with_fd created [ Unix.O_CREAT; Unix.O_WRONLY ] (fun _ -> ()));
             assert_denied "other character device write" Unix.EACCES (fun () ->
               with_fd "/dev/zero" [ Unix.O_WRONLY ] (fun _ -> ()));
             List.iter
               (fun kind ->
                  assert_denied "network socket" Unix.EPERM (fun () ->
                    Unix.close (Unix.socket Unix.PF_INET kind 0)))
               [ Unix.SOCK_STREAM; Unix.SOCK_DGRAM ];
             with_fd scratch_file [ Unix.O_CREAT; Unix.O_WRONLY ] (fun fd ->
               check int "scratch is still writable" 1 (Unix.write_substring fd "x" 0 1));
             0
           with
           | exn ->
             prerr_endline (Printexc.to_string exn);
             1
         in
         flush_all ();
         Unix._exit status);
       let _, status = Unix.waitpid [] pid in
       check bool "actual Observe child passed" true (status = Unix.WEXITED 0);
       with_fd persistent [ Unix.O_RDONLY ] (fun fd ->
         let bytes = Bytes.create (String.length sentinel + 1) in
         let count = Unix.read fd bytes 0 (Bytes.length bytes) in
         check
           string
           "workspace content unchanged"
           sentinel
           (Bytes.sub_string bytes 0 count));
       check bool "workspace file not created" false (Sys.file_exists created);
       Printf.printf
         "Observe child: /dev/null read/write and shell discard succeeded; persistent \
          writes, creation, TCP/UDP sockets denied; parent verified unchanged content.\n\
          %!")
;;

let test_git_status_fsmonitor_is_confined () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  check bool "Observe boundary available" true (Exec_shim.observe_supported ());
  let root = Filename.temp_dir "masc-status-observe-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) @@ fun () ->
  let scratch = Filename.concat root "scratch" in
  Unix.mkdir scratch 0o700;
  let git_env = [| "PATH=" ^ Sys.getenv "PATH"; "HOME=" ^ root;
    "GIT_CONFIG_NOSYSTEM=1"; "GIT_CONFIG_GLOBAL=/dev/null" |] in
  let git args =
    let argv = Array.of_list (["git"; "-C"; root] @ args) in
    let pid = Unix.create_process_env "git" argv git_env Unix.stdin Unix.stdout Unix.stderr in
    snd (Unix.waitpid [] pid) in
  let git_ok args = check bool "Git fixture command succeeds" true (git args = Unix.WEXITED 0) in
  git_ok ["-c"; "init.templateDir="; "init"; "--quiet"];
  Fs_compat.save_file (Filename.concat root "tracked.txt") "tracked\n";
  git_ok ["add"; "tracked.txt"];
  let hook = Filename.concat root ".git/fsmonitor-probe" in
  Fs_compat.save_file hook "#!/bin/sh\nprintf invoked > 'scratch/fsmonitor-invoked'\nprintf observed > '.git/fsmonitor-invoked'\nprintf \"token\\000\"\n";
  Unix.chmod hook 0o700;
  git_ok ["config"; "core.fsmonitor"; hook];
  git_ok ["status"; "--short"];
  let marker = Filename.concat root ".git/fsmonitor-invoked" in
  check string "plain status invokes a writing repository hook" "observed" (Fs_compat.load_file marker);
  let invocation_marker = Filename.concat scratch "fsmonitor-invoked" in
  check string "baseline hook also records invocation" "invoked" (Fs_compat.load_file invocation_marker);
  Sys.remove marker;
  Sys.remove invocation_marker;
  flush_all ();
  let pid = Unix.fork () in
  if pid = 0 then (
    let exit_code = try
      restrict_self scratch true true;
      git_ok ["status"; "--short"];
      0
    with error -> prerr_endline (Printexc.to_string error); 1 in
    flush_all (); Unix._exit exit_code);
  check bool "status remains executable under enforced Observe" true
    (snd (Unix.waitpid [] pid) = Unix.WEXITED 0);
  check string "confined hook actually executed" "invoked" (Fs_compat.load_file invocation_marker);
  check bool "Observe prevents fsmonitor persistent write" false (Sys.file_exists marker)
;;

let () =
  run
    "exec shim Observe"
    [ ( "Git repository hooks", [test_case "status fsmonitor effects stay confined" `Quick test_git_status_fsmonitor_is_confined] )
    ; ( "discard device"
      , [ test_case
            "discard output without persistent effects"
            `Quick
            test_observe_discard_without_persistent_effects
        ] )
    ]
;;
