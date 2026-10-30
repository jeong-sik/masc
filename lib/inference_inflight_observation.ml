(** MASC-visible observation of inference calls.

    Provider capacity, retry, and throttling belong to AGENT_CORE.  This module never
    admits, rejects, ranks, queues, or delays a Keeper.  It only exposes the
    number of MASC calls currently crossing the AGENT_CORE boundary. *)

type t =
  { mutable active : int
  ; mutex : Eio.Mutex.t
  }

let global = { active = 0; mutex = Eio.Mutex.create () }

let log_observation_failure operation exn =
  Log.Misc.warn
    "inference inflight observation failed during %s: %s"
    operation
    (Printexc.to_string exn)
;;

(* Both call sites break if this propagates. The "acquire" one runs after
   [update_active 1] and before [Eio_guard.protect] installs the matching
   decrement, so a raise there strands the counter for the life of the
   process -- and [update_active] fails hard on underflow, which makes the
   skew permanent. The "release" one runs inside that guard's finally, where
   a raise replaces the exception being unwound. *)
let observe_metric operation f =
  match f () with
  | () -> ()
  | exception exn -> log_observation_failure operation exn (* cancel-guard-ok: acquire runs before the matching decrement is installed and release runs inside the finally; raising from either strands the counter or replaces the unwinding exception *)
;;

let update_active delta =
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    let next = global.active + delta in
    if next < 0
    then
      failwith
        (Printf.sprintf
           "inference inflight counter underflow: active=%d delta=%d"
           global.active
           delta);
    global.active <- next)
;;

let with_observation ~keeper_name ~runtime_id f =
  update_active 1;
  observe_metric "acquire" (fun () ->
    let _ = keeper_name, runtime_id in
    Otel_metric_store.inc_gauge Otel_metric_store.metric_inference_inflight ();
    Otel_metric_store.inc_counter Otel_metric_store.metric_inference_started ());
  Eio_guard.protect
    ~finally:(fun () ->
      update_active (-1);
      observe_metric "release" (fun () ->
        let _ = keeper_name, runtime_id in
        Otel_metric_store.dec_gauge Otel_metric_store.metric_inference_inflight ()))
    f
;;

let active () = Eio.Mutex.use_ro global.mutex (fun () -> global.active)

let snapshot_json () =
  `Assoc
    [ "boundary_owner", `String "agent_core_runtime"
    ; "active", `Int (active ())
    ]
;;

module For_testing = struct
  let reset () = Eio.Mutex.use_rw ~protect:true global.mutex (fun () -> global.active <- 0)
end
