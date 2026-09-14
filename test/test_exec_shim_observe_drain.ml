open Alcotest

(* End-to-end for the task-1571 observation path.  The child installs a
   SECCOMP_RET_USER_NOTIF filter on socket(2), hands the listener fd to the
   parent over a unix-domain socket, then calls socket(2).  The parent
   receives the fd, drains one notification, answers EPERM, and the child's
   socket(2) returns EPERM.  This is the "record the attempt, then refuse"
   shape the design note defers to phase 2 — the refusal now carries
   evidence of the attempt itself, not only "the box applied". *)

external observe_install : Unix.file_descr -> bool = "ocaml_shim_observe_install"
external drain : Unix.file_descr -> int = "ocaml_shim_user_notif_drain"

let child_exit_ok = 0
let child_exit_install_failed = 3
let child_exit_not_denied = 4

let test_observe_records_and_denies_socket () =
  check bool "kernel must support user_notif" true (Exec_shim.user_notif_supported ());
  let a, b = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close b)
    (fun () ->
       let pid = Unix.fork () in
       match pid with
       | 0 ->
         (* child: install the observe filter, hand the fd over, then make
            the attempt the parent must record. *)
         (try
            Unix.close b;
            if not (observe_install a)
            then exit child_exit_install_failed;
            (match Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 with
             | fd ->
               Unix.close fd;
               exit child_exit_not_denied
             | exception Unix.Unix_error (Unix.EPERM, _, _) -> exit child_exit_ok
             | exception _ -> exit child_exit_not_denied)
          with _ -> exit child_exit_install_failed)
       | pid ->
         Unix.close a;
         let listener = Shim_fdpass.recv_fd b in
         Fun.protect
           ~finally:(fun () -> Unix.close listener)
           (fun () -> check int "one socket attempt recorded" 1 (drain listener));
         let _, status = Unix.waitpid [] pid in
         check
           int
           "child saw EPERM"
           child_exit_ok
           (match status with
            | Unix.WEXITED c -> c
            | Unix.WSIGNALED s -> 128 + s
            | Unix.WSTOPPED s -> 128 + s))
;;

let () =
  run
    "exec shim observe drain"
    [ ( "user_notif"
      , [ test_case
            "socket attempt is recorded then denied"
            `Quick
            test_observe_records_and_denies_socket
        ] ) ]
;;
