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
                 [| "git"; "diff"; "--no-index"; "--no-ext-diff";
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

let () =
  run
    "exec shim Observe"
    [ ( "discard device"
      , [ test_case
            "discard output without persistent effects"
            `Quick
            test_observe_discard_without_persistent_effects
        ] )
    ]
;;
