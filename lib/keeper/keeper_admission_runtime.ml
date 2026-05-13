(* See keeper_admission_runtime.mli for documentation. *)

let no_policy : Keeper_admission_glue.policy_lookup = fun _ -> None
let no_bucket : Keeper_admission_router.bucket_lookup = fun _ -> None

(* WFQ overflow queue for keepers that got [Wait] decisions.
   Shared across all keepers; heartbeat loop enqueues / wake hook dequeues. *)
let wfq_queue : Keeper_wfq_overflow.t = Keeper_wfq_overflow.create ()

(* Use [Atomic.t] for callback refs, matching the convention in
   [Coord_hooks] (lib/coord/coord_hooks.ml).  Plain [ref] is not safe
   across domains in OCaml 5; the Atomic primitives provide the
   release/acquire semantics we want for cross-fiber callback swaps. *)
let policy_lookup_ref : Keeper_admission_glue.policy_lookup Atomic.t =
  Atomic.make no_policy
;;

let bucket_lookup_ref : Keeper_admission_router.bucket_lookup Atomic.t =
  Atomic.make no_bucket
;;

(* Three-state init flag.  We hold [init_mutex] only while transitioning
   between states — never across the file I/O step.

     Idle      : nothing tried yet.  Eligible to take ownership.
     In_progress : one fiber is reading cascade.toml right now.  Other
                   fibers see this and skip without blocking.
     Done      : registry installed (or load failed and we logged).
                 Subsequent calls are no-ops. *)
type init_state =
  | Idle
  | In_progress
  | Done

let init_mutex = Stdlib.Mutex.create ()
let init_state = ref Idle
let set_policy_lookup f = Atomic.set policy_lookup_ref f
let set_bucket_lookup f = Atomic.set bucket_lookup_ref f

(* Per-provider rate config.  PR-E-1.8 reads from cascade config;
   falls back to hard-coded defaults when no config is present. *)
let default_bucket_capacity = 10
let default_bucket_refill_rate = 1.0
let now () = Unix.gettimeofday ()

(* Attempt to read per-provider rate config from the in-memory cascade view.
   Returns (capacity, refill_rate) or None if not found. *)
let read_provider_rate_config ~provider json =
  let open Yojson.Safe.Util in
  try
    let rates = member "admission" json |> member "provider_rates" in
    let provider_obj = member provider rates in
    let capacity =
      member "capacity" provider_obj
      |> to_int_option
      |> Option.value ~default:default_bucket_capacity
    in
    let refill_rate =
      member "refill_rate" provider_obj
      |> to_float_option
      |> Option.value ~default:default_bucket_refill_rate
    in
    Some (capacity, refill_rate)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_admission_runtime: admission.provider_rates parse failed for \
       provider=%s: %s"
      provider
      (Printexc.to_string exn);
    None
;;

(* Build a lazy bucket lookup that reads per-provider rates from
   the rendered cascade source when available. *)
let make_lazy_bucket_lookup ~cascade_view_opt () =
  let table : (string, Keeper_provider_token_bucket.t) Hashtbl.t = Hashtbl.create 16 in
  let table_mutex = Stdlib.Mutex.create () in
  fun provider ->
    Stdlib.Mutex.protect table_mutex (fun () ->
      match Hashtbl.find_opt table provider with
      | Some b -> Some b
      | None ->
        let capacity, refill_rate =
          match cascade_view_opt with
          | Some json ->
            (match read_provider_rate_config ~provider json with
             | Some (c, r) -> c, r
             | None -> default_bucket_capacity, default_bucket_refill_rate)
          | None -> default_bucket_capacity, default_bucket_refill_rate
        in
        let b =
          Keeper_provider_token_bucket.create ~provider ~capacity ~refill_rate ~now
        in
        (* Register WFQ wake hook: when this provider's bucket refills
             from < 1.0 to >= 1.0, try to wake one waiting keeper. *)
        Keeper_provider_token_bucket.add_on_refill b (fun () ->
          match Keeper_wfq_overflow.wake_one wfq_queue with
          | None -> ()
          | Some _entry ->
            (* Woken keeper will be reconsidered on its next heartbeat
                   tick; we do NOT synchronously dispatch here to avoid
                   nested admission decisions inside the refill callback. *)
            ());
        Hashtbl.add table provider b;
        Some b)
;;

(* Try to claim the init slot.  Returns [true] if this fiber should
   run the load now; [false] if another fiber is already running or
   has already finished.  Mutex is held only for the state read and
   transition, never across the file I/O. *)
let try_claim_init () =
  Stdlib.Mutex.protect init_mutex (fun () ->
    match !init_state with
    | Done -> false
    | In_progress -> false
    | Idle ->
      init_state := In_progress;
      true)
;;

let mark_init_done () = Stdlib.Mutex.protect init_mutex (fun () -> init_state := Done)

(* Failure path: revert to Idle so a future heartbeat tick can retry.
   Without this, a transient I/O hiccup at startup would pin the
   process in legacy mode for its lifetime. *)
let revert_init_to_idle () =
  Stdlib.Mutex.protect init_mutex (fun () -> init_state := Idle)
;;

let init_once_from_base_path ~base_path =
  if not (try_claim_init ())
  then ()
  else (
    (* I/O outside the critical section.
       [Cascade_config_loader.load_catalog_source] can call [Eio.traceln]
       and may block on disk — holding [init_mutex] across that risks
       domain-wide stalls of any other fiber that hits this code.

       The retired JSON compatibility path is gone; callers now pass the
       TOML source path directly. *)
    let cascade_source_path =
      Filename.concat
        (Filename.concat base_path ".masc/config")
        Config_dir_resolver.cascade_toml_filename
    in
    match Cascade_config_loader.load_catalog_source cascade_source_path with
    | Error msg ->
      (* Transient or permanent read failure — leave registry empty,
           revert to Idle so the next heartbeat tick can retry. *)
      revert_init_to_idle ();
      Log.Keeper.warn
        "RFC-0026 PR-E-1.6: cascade.toml load failed (%s); admission registry stays \
         empty, observe will return Legacy_path (will retry on next tick)"
        msg
    | Ok json ->
      let registry, errors = Keeper_admission_registry.load_from_json json in
      List.iter
        (fun (e : Keeper_admission_registry.load_error) ->
           Log.Keeper.warn
             "RFC-0026 PR-E-1.6: admission policy parse failed for keeper=%s"
             e.keeper_id)
        errors;
      let registered = Keeper_admission_registry.size registry in
      (* Install lookups via Atomic.set, then mark Done.  Order
           matters: a parallel fiber reading [policy_lookup] should
           never observe Done with the default [no_policy]. *)
      set_policy_lookup (fun id -> Keeper_admission_registry.lookup registry id);
      set_bucket_lookup (make_lazy_bucket_lookup ~cascade_view_opt:(Some json) ());
      mark_init_done ();
      Log.Keeper.info
        "RFC-0026 PR-E-1.6: admission runtime initialised (policies=%d, errors=%d, \
         base_path=%s)"
        registered
        (List.length errors)
        base_path)
;;

let policy_lookup keeper_id = (Atomic.get policy_lookup_ref) keeper_id
let bucket_lookup provider = (Atomic.get bucket_lookup_ref) provider

let outcome_label (outcome : Keeper_admission_glue.outcome) : string =
  match outcome with
  | Keeper_admission_glue.Legacy_path -> "legacy"
  | Keeper_admission_glue.New_admission decision ->
    (match decision with
     | Keeper_admission_router.Dispatch _ -> "dispatch"
     | Keeper_admission_router.Wait -> "wait"
     | Keeper_admission_router.Surface _ -> "surface")
;;

let observe ~keeper_id =
  (* Use [decide_shadow] (not [decide]): we want the would-be outcome
     regardless of [MASC_ADMISSION_USE_NEW], and we must not consume
     bucket tokens since the legacy semaphore path still owns
     dispatch.  See keeper_admission_glue.mli for the rationale. *)
  let outcome =
    Keeper_admission_glue.decide_shadow
      ~keeper_id
      ~policies:policy_lookup
      ~buckets:bucket_lookup
  in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_admission_shadow_outcome
    ~labels:[ "keeper", keeper_id; "outcome", outcome_label outcome ]
    ();
  outcome
;;

(** Live admission decision (Phase A1).  Consumes tokens on Dispatch,
    enqueues on Wait, surfaces on Surface, falls through to legacy on
    Legacy_path.

    Returns the decision + the acquired bucket (if Dispatch) so the
    caller can release it after the turn completes. *)
type live_result =
  | Live_dispatch of
      { candidate : Keeper_admission_policy.candidate
      ; drift : Keeper_admission_router.drift_record
      ; bucket : Keeper_provider_token_bucket.t
      }
  | Live_wait
  | Live_surface of Keeper_admission_router.surface_reason
  | Live_legacy

let live_result_label = function
  | Live_dispatch _ -> "dispatch"
  | Live_wait -> "wait"
  | Live_surface _ -> "surface"
  | Live_legacy -> "legacy"
;;

let decide_live ~keeper_id =
  let outcome =
    Keeper_admission_glue.decide ~keeper_id ~policies:policy_lookup ~buckets:bucket_lookup
  in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_admission_shadow_outcome
    ~labels:[ "keeper", keeper_id; "outcome", outcome_label outcome ]
    ();
  match outcome with
  | Keeper_admission_glue.Legacy_path -> Live_legacy
  | Keeper_admission_glue.New_admission decision ->
    (match decision with
     | Keeper_admission_router.Dispatch { candidate; drift } ->
       (* Look up the bucket again to return it for release. *)
       (match bucket_lookup candidate.Keeper_admission_policy.provider with
        | Some bucket -> Live_dispatch { candidate; drift; bucket }
        | None ->
          (* Should not happen: decide already acquired from this
                   bucket.  Fall back to legacy for safety. *)
          Log.Keeper.warn
            "%s: admission dispatch bucket disappeared after acquire; falling back to \
             legacy"
            keeper_id;
          Live_legacy)
     | Keeper_admission_router.Wait ->
       (* Enqueue in WFQ overflow for wake on refill. *)
       let policy_opt = policy_lookup keeper_id in
       let weight =
         match policy_opt with
         | Some p -> Keeper_admission_policy.weight p
         | None -> 1
       in
       Keeper_wfq_overflow.enqueue wfq_queue { keeper_id; weight; enqueued_at = now () };
       Live_wait
     | Keeper_admission_router.Surface reason -> Live_surface reason)
;;

(** Release a bucket token after turn completion.  Idempotent — safe
    to call even if the token was never acquired (e.g. after exception
    paths that short-circuit before dispatch). *)
let release_bucket bucket = Keeper_provider_token_bucket.release bucket

let wfq_depth () = Keeper_wfq_overflow.depth wfq_queue
let wfq_snapshot () = Keeper_wfq_overflow.snapshot wfq_queue

let reset_for_test () =
  Stdlib.Mutex.protect init_mutex (fun () ->
    Atomic.set policy_lookup_ref no_policy;
    Atomic.set bucket_lookup_ref no_bucket;
    init_state := Idle)
;;
