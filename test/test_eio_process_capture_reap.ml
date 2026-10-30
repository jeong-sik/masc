(* [reap_proc_with_clock] ends the stop of a spawned host, so a failure of its
   last wait must not leave it: the callers run it from a [Fun.protect]
   finalizer, where an exception replaces the result of the turn the host
   served. *)

module Failing_process = struct
  type t = unit
  type tag = [ `Generic ]

  let pid () = 1
  let await () : Eio.Process.exit_status = failwith "waitpid failed"
  let signal () (_ : int) = ()
end

(* A process whose exit status can never be read, as when [waitpid] fails
   after the child was reaped elsewhere. *)
let failing_process : [ `Generic ] Eio.Process.ty Eio.Resource.t =
  Eio.Resource.T ((), Eio.Process.Pi.process (module Failing_process))
;;

let test_a_wait_that_fails_does_not_escape_the_reap () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      Eio_process_capture.reap_proc_with_clock
        ~sw
        (Eio.Stdenv.clock env :> float Eio.Time.clock_ty Eio.Resource.t)
        failing_process))
;;

let () =
  Alcotest.run
    "eio_process_capture_reap"
    [ ( "reap_proc_with_clock"
      , [ Alcotest.test_case
            "a wait that fails does not escape the reap"
            `Quick
            test_a_wait_that_fails_does_not_escape_the_reap
        ] )
    ]
;;
