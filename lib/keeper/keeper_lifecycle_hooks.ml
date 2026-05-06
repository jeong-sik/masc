(** Implementation of Keeper_lifecycle_hooks. See .mli for contract. *)

type event =
  | Phase_transition of {
      from_phase : Keeper_state_machine.phase;
      to_phase   : Keeper_state_machine.phase;
    }
  | Tombstone_reaped

type hook = keeper_id:string -> event -> unit

(* Atomic-backed reversed-list. Registration prepends ([h :: cur]) which
   is O(1); the runner then iterates the reversed list in registration
   order via List.rev once per [run] call. The previous [cur @ [h]]
   form was O(n) per register and re-allocated the entire list under
   compare_and_set retries — quickly costly under contention even
   though hooks/run is rare on the hot path. *)
let hooks : hook list Atomic.t = Atomic.make []

let register (h : hook) : unit =
  let rec loop () =
    let cur = Atomic.get hooks in
    let next = h :: cur in
    if Atomic.compare_and_set hooks cur next then ()
    else loop ()
  in
  loop ()

let run ~keeper_id (ev : event) : unit =
  (* Reverse once at run time so call order matches registration order
     (the documented contract). The reversal is O(n) but n is tiny in
     practice (a handful of subsystem hooks). *)
  let hs = List.rev (Atomic.get hooks) in
  List.iter
    (fun h ->
      try h ~keeper_id ev
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Prometheus.inc_counter
          Prometheus.metric_keeper_lifecycle_callback_failures
          ~labels:
            [
              ("keeper", keeper_id);
              ("callback", "keeper_lifecycle_hook");
            ]
          ();
        Log.Server.warn
          "[KeeperLifecycleHooks] hook raised on keeper_id=%s: %s"
          keeper_id (Printexc.to_string exn))
    hs

let registered_count () : int = List.length (Atomic.get hooks)

let reset_for_testing () : unit = Atomic.set hooks []
