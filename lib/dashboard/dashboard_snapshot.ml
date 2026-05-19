(** See [dashboard_snapshot.mli] for the public contract.

    This is the Phase 3 prototype landing for RFC-0138.  Only the
    storage primitive + bootstrap path are implemented in this PR;
    handler wiring lands in a follow-up. *)

type t = {
  generated_at : float;
  generation : int;
  shell : Yojson.Safe.t;
  tools : Yojson.Safe.t;
  namespace_truth : Yojson.Safe.t;
  telemetry_summary : Yojson.Safe.t;
}

(* Lock-free publish slot.  Holds [None] before the first publish so
   readers can distinguish "not yet warmed" from a real empty snapshot
   (the latter never occurs in normal operation). *)
let slot : t option Atomic.t = Atomic.make None

(* Monotonic publish counter.  Independent atomic so a reader observing
   a fresh [t] always sees an increasing [generation] without contention
   on the slot atomic. *)
let generation_counter = Atomic.make 0

let next_generation () = Atomic.fetch_and_add generation_counter 1 + 1

let current () = Atomic.get slot

(* Bootstrap once: if no live snapshot exists, compute one synchronously
   and publish so subsequent readers do not pay the cost.  A second
   concurrent caller observing [None] races to compute; the
   [Atomic.compare_and_set] keeps only one winner and the loser's work
   is discarded.  Acceptable: bootstrap happens at most a few times per
   process lifetime. *)
let bootstrap ~(config : Coord.config) : t =
  let shell =
    try
      Server_dashboard_http_core.dashboard_shell_payload_json config
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap shell failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  let tools =
    try
      Server_dashboard_http_runtime_info.dashboard_tools_http_json config
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap tools failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  let telemetry_summary =
    try
      let base_path = config.base_path in
      let masc_root = Coord.masc_root_dir config in
      Telemetry_unified.summary_json ~base_path ~masc_root ()
    with exn ->
      Log.Dashboard.warn "dashboard_snapshot bootstrap telemetry_summary failed: %s"
        (Printexc.to_string exn);
      `Null
  in
  (* namespace_truth requires Eio context; the bootstrap path runs on
     whatever fiber called it.  Until handler wire lands, surface a
     null placeholder so the snapshot type is total — the refresh
     fiber will replace it on first interval. *)
  let namespace_truth = `Null in
  let t =
    {
      generated_at = Unix.gettimeofday ();
      generation = next_generation ();
      shell;
      tools;
      namespace_truth;
      telemetry_summary;
    }
  in
  (* Publish only if the slot is still empty — never overwrite a
     refresh-fiber publish with a bootstrap value. *)
  ignore (Atomic.compare_and_set slot None (Some t));
  t
;;

let current_or_bootstrap ~config =
  match Atomic.get slot with
  | Some t -> t
  | None -> bootstrap ~config
;;

(* RFC-0138 Phase 3 Step 3: refresh loop now optionally accepts the
   server_state so it can populate [namespace_truth] from the cached
   refs that [Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches]
   exposes.  That function reads only process-local refs (no PG I/O,
   no fiber timeouts), so it is safe in a background fiber — moving
   the read here is what retires the 6 MASC_NAMESPACE_TRUTH_*_TIMEOUT_S
   env knobs from the request path (Step 4). *)
let refresh_loop
      ~sw:_ ~clock ~config ?state ~interval_sec ()
  =
  let log_failure label exn =
    Log.Dashboard.warn
      "dashboard_snapshot refresh: %s failed (snapshot held at previous publish): %s"
      label (Printexc.to_string exn)
  in
  let safe label f =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      log_failure label exn;
      `Null
  in
  let compute () =
    let shell =
      safe "shell" (fun () ->
        Server_dashboard_http_core.dashboard_shell_payload_json config)
    in
    let tools =
      safe "tools" (fun () ->
        Server_dashboard_http_runtime_info.dashboard_tools_http_json config)
    in
    let telemetry_summary =
      safe "telemetry_summary" (fun () ->
        let base_path = config.base_path in
        let masc_root = Coord.masc_root_dir config in
        Telemetry_unified.summary_json ~base_path ~masc_root ())
    in
    let namespace_truth =
      match state with
      | None -> `Null
      | Some state ->
        safe "namespace_truth" (fun () ->
          match
            Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches
              state
          with
          | Some json -> json
          | None -> `Null)
    in
    {
      generated_at = Unix.gettimeofday ();
      generation = next_generation ();
      shell;
      tools;
      namespace_truth;
      telemetry_summary;
    }
  in
  let rec loop () =
    (match
       (* If the whole compute path fails (e.g. exception escapes a
          [safe] wrapper), keep the previous snapshot live. *)
       try Some (compute ()) with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         log_failure "compute" exn;
         None
     with
     | Some t -> Atomic.set slot (Some t)
     | None -> ());
    Eio.Time.sleep clock interval_sec;
    loop ()
  in
  loop ()
;;

let publish_for_test t = Atomic.set slot (Some t)

let make_for_test ~shell ~tools ~namespace_truth ~telemetry_summary =
  {
    generated_at = Unix.gettimeofday ();
    generation = next_generation ();
    shell;
    tools;
    namespace_truth;
    telemetry_summary;
  }
;;

let reset_for_test () = Atomic.set slot None
