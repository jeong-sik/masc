open Alcotest

(* Exercise the SCM_RIGHTS stub in a disposable child: the child opens a
   file and hands the descriptor to the parent over a unix-domain socket,
   and the parent reads the same bytes through the received descriptor.
   This is the fd-passing primitive task-1571 (phase 2) needs to move a
   SECCOMP_FILTER_FLAG_NEW_LISTENER fd from the child (where the filter is
   installed) to the shim (which polls it).

   Single-close discipline: the parent closes [a] exactly once (in the
   body), [b] exactly once (in the finally).  The child closes its own
   copies — fork gives it a separate descriptor table, so its closes do
   not touch the parent's.  The child reports failure through its exit
   status so a dead child cannot masquerade as a short read.

   scripts/ci/run-edited-tests.sh selects a suite for an edited source by
   an exact quoted path match, not by directory: this suite exercises
   "lib/exec_shim/fdpass_stub.c" and "lib/exec_shim/shim_fdpass.ml"
   directly, so both are named here to stay selected when either changes
   (review 5198897765 on PR #36319, observation 3). *)

let child_exit_ok = 0
let child_exit_send_failed = 3

let with_fd path flags f =
  let fd = Unix.openfile path flags 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd)
;;

let test_fd_passes_over_socketpair () =
  let path = Filename.temp_file "masc-fdpass-" ".txt" in
  let sentinel = "fd passing sentinel" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       with_fd path [ Unix.O_CREAT; Unix.O_WRONLY ] (fun fd ->
         ignore (Unix.write_substring fd sentinel 0 (String.length sentinel)));
       let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
       Fun.protect
         ~finally:(fun () -> Unix.close b)
         (fun () ->
            let pid = Unix.fork () in
            match pid with
            | 0 ->
              (* child: hand the descriptor to the parent, then die
                 quietly — never run alcotest's at_exit machinery. *)
              (try
                 Unix.close b;
                 let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
                 Shim_fdpass.send_fd a fd;
                 Unix.close fd;
                 Unix.close a;
                 exit child_exit_ok
               with _ -> exit child_exit_send_failed)
            | pid ->
              Unix.close a;
              let received = Shim_fdpass.recv_fd b in
              Fun.protect
                ~finally:(fun () -> Unix.close received)
                (fun () ->
                   let buf = Bytes.create (String.length sentinel) in
                   let n = Unix.read received buf 0 (Bytes.length buf) in
                   check int "received length" (String.length sentinel) n;
                   check string "received content" sentinel (Bytes.sub_string buf 0 n));
              let _, status = Unix.waitpid [] pid in
              check
                int
                "child exit status"
                child_exit_ok
                (match status with
                 | Unix.WEXITED c -> c
                 | Unix.WSIGNALED s -> 128 + s
                 | Unix.WSTOPPED s -> 128 + s)))
;;

let () =
  run
    "shim_fdpass"
    [ ( "scm_rights"
      , [ test_case "fd passes over socketpair" `Quick test_fd_passes_over_socketpair ]
      ) ]
;;
