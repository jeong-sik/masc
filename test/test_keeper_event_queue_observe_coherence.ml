(** Regression: the read-only queue observer must reject a torn read.

    #28191 added the two-sample observer and the [For_testing] interleave seam
    without a test that uses it. The sample comparison was written as a partial
    application — [stable_read_only_observation ~keeper_name] handed to
    [Result.bind], which supplies only the second sample — so
    [lib/keeper_runtime] did not compile and [bin/main_eio.exe] could not be
    built from main.

    The compile fix is proven by the compiler. This test pins the part the
    compiler cannot see: a comparison of the second sample with itself
    type-checks and reports every read as coherent. Here the persisted queue
    changes between the two samples, so only a genuine first-vs-second
    comparison reports [Incoherent_read]. *)

module Persistence = Keeper_event_queue_persistence
module Queue = Keeper_event_queue

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Unix.unlink path
;;

(* [Bootstrap] is the one nullary payload, so the stimulus carries no producer
   context the observer could read; the queue only has to differ. *)
let bootstrap_stimulus post_id : Queue.stimulus =
  { post_id; urgency = Queue.Normal; arrived_at = 0.0; payload = Queue.Bootstrap }
;;

let has_incoherent_read (snapshot : Persistence.snapshot_with_errors) =
  List.exists
    (fun (error : Persistence.snapshot_read_error) ->
       error.kind = Persistence.Incoherent_read)
    snapshot.read_errors
;;

let () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let net = Eio.Stdenv.net env in
  Eio.Switch.run
  @@ fun sw ->
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw
  @@ fun () ->
  let keeper_name = "observe_coherence_probe" in
  let base_path = Filename.temp_file "kq_observe_probe" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists base_path then rm_rf base_path)
    (fun () ->
       Persistence.persist ~base_path ~keeper_name Queue.empty;
       (* Two identical samples: a coherent observation with no read errors. *)
       let stable =
         Persistence.For_testing.observe_snapshot_with_errors_with_interleave
           ~between_samples:(fun () -> ())
           ~base_path
           ~keeper_name
       in
       Alcotest.(check int)
         "an unchanged queue observes coherently"
         0
         (List.length stable.read_errors);
       Alcotest.(check bool)
         "the coherent observation projects the persisted queue"
         true
         (Queue.is_empty stable.pending);
       (* The queue changes between the two samples. The observer must report
          the torn read rather than project either half. *)
       let torn =
         Persistence.For_testing.observe_snapshot_with_errors_with_interleave
           ~between_samples:(fun () ->
             Persistence.persist
               ~base_path
               ~keeper_name
               (Queue.enqueue Queue.empty (bootstrap_stimulus "torn-1")))
           ~base_path
           ~keeper_name
       in
       Alcotest.(check bool)
         "a queue that changes between samples is an incoherent read"
         true
         (has_incoherent_read torn);
       Alcotest.(check bool)
         "an incoherent read projects no pending work"
         true
         (Queue.is_empty torn.pending));
  print_endline "test_keeper_event_queue_observe_coherence: OK"
;;
