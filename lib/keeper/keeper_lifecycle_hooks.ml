(** Implementation of Keeper_lifecycle_hooks. See .mli for contract. *)

type event =
  | Phase_transition of {
      from_phase : Keeper_state_machine.phase;
      to_phase   : Keeper_state_machine.phase;
    }
  | Tombstone_reaped

type hook = keeper_id:string -> event -> unit

let callback_label = "keeper_lifecycle_hook"
let coverage_source = "keeper_lifecycle_callback"
let coverage_durable_store = "keeper_lifecycle_events"
let coverage_dashboard_surface = "keeper_lifecycle"
let coverage_stale_reason = "callback_exception"

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

let record_coverage_gap ?base_dir ?meta ~callback ~error () =
  match base_dir, meta with
  | Some masc_root, Some (meta : Keeper_types.keeper_meta) -> (
      try
        Telemetry_coverage_gap.record
          ~masc_root
          ~source:coverage_source
          ~producer:callback
          ~durable_store:coverage_durable_store
          ~dashboard_surface:coverage_dashboard_surface
          ~stale_reason:coverage_stale_reason
          ~keeper_name:meta.name
          ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
          ~error
          ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | gap_exn ->
        Log.Keeper.warn
          "keeper:%s lifecycle hook coverage-gap record failed: %s"
          meta.name (Printexc.to_string gap_exn))
  | _ -> ()

let run ?base_dir ?meta ~keeper_id (ev : event) : unit =
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
        let error = Printexc.to_string exn in
        Prometheus.inc_counter
          Prometheus.metric_keeper_lifecycle_callback_failures
          ~labels:
            [
              ("keeper", keeper_id);
              ("callback", callback_label);
            ]
          ();
        Log.Server.warn
          "[KeeperLifecycleHooks] hook raised on keeper_id=%s: %s"
          keeper_id error;
        record_coverage_gap ?base_dir ?meta ~callback:callback_label ~error ())
    hs

let registered_count () : int = List.length (Atomic.get hooks)

let reset_for_testing () : unit = Atomic.set hooks []
