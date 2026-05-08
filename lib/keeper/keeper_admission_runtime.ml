(* See keeper_admission_runtime.mli for documentation. *)

let no_policy : Keeper_admission_glue.policy_lookup = fun _ -> None
let no_bucket : Keeper_admission_router.bucket_lookup = fun _ -> None

(* Use [Atomic.t] for callback refs, matching the convention in
   [Coord_hooks] (lib/coord/coord_hooks.ml).  Plain [ref] is not safe
   across domains in OCaml 5; the Atomic primitives provide the
   release/acquire semantics we want for cross-fiber callback swaps. *)
let policy_lookup_ref : Keeper_admission_glue.policy_lookup Atomic.t =
  Atomic.make no_policy
let bucket_lookup_ref : Keeper_admission_router.bucket_lookup Atomic.t =
  Atomic.make no_bucket

(* Three-state init flag.  We hold [init_mutex] only while transitioning
   between states — never across the file I/O step.

     Idle      : nothing tried yet.  Eligible to take ownership.
     In_progress : one fiber is reading cascade.json right now.  Other
                   fibers see this and skip without blocking.
     Done      : registry installed (or load failed and we logged).
                 Subsequent calls are no-ops. *)
type init_state = Idle | In_progress | Done
let init_mutex = Stdlib.Mutex.create ()
let init_state = ref Idle

let set_policy_lookup f = Atomic.set policy_lookup_ref f
let set_bucket_lookup f = Atomic.set bucket_lookup_ref f

(* Lazy per-provider bucket table.  PR-E-1.8 will replace the
   hard-coded defaults with per-provider rate config sourced from
   cascade.toml.  For PR-E-1.6+1.7 we just want every provider name
   referenced by an [admission.<keeper>].candidates entry to map to a
   non-empty bucket so [Keeper_admission_router.schedule] can return
   [Dispatch] / [Wait] in the shadow counter — same shape it will
   take in PR-E-1.8 once rates are real. *)
let default_bucket_capacity = 10
let default_bucket_refill_rate = 1.0
let now () = Unix.gettimeofday ()

let make_lazy_bucket_lookup () =
  let table : (string, Keeper_provider_token_bucket.t) Hashtbl.t =
    Hashtbl.create 16
  in
  let table_mutex = Stdlib.Mutex.create () in
  fun provider ->
    Stdlib.Mutex.protect table_mutex (fun () ->
      match Hashtbl.find_opt table provider with
      | Some b -> Some b
      | None ->
          let b =
            Keeper_provider_token_bucket.create
              ~provider
              ~capacity:default_bucket_capacity
              ~refill_rate:default_bucket_refill_rate
              ~now
          in
          Hashtbl.add table provider b;
          Some b)

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

let mark_init_done () =
  Stdlib.Mutex.protect init_mutex (fun () -> init_state := Done)

(* Failure path: revert to Idle so a future heartbeat tick can retry.
   Without this, a transient I/O hiccup at startup would pin the
   process in legacy mode for its lifetime. *)
let revert_init_to_idle () =
  Stdlib.Mutex.protect init_mutex (fun () -> init_state := Idle)

let init_once_from_base_path ~base_path =
  if not (try_claim_init ()) then ()
  else begin
    (* I/O outside the critical section.  [Cascade_config_loader.load_json]
       can call [Eio.traceln] and may block on disk — holding [init_mutex]
       across that risks domain-wide stalls of any other fiber that hits
       this code. *)
    let cascade_json_path =
      Filename.concat (Filename.concat base_path ".masc/config")
        "cascade.json"
    in
    match Cascade_config_loader.load_json cascade_json_path with
    | Error msg ->
        (* Transient or permanent read failure — leave registry empty,
           revert to Idle so the next heartbeat tick can retry. *)
        revert_init_to_idle ();
        Log.Keeper.warn
          "RFC-0026 PR-E-1.6: cascade.json load failed (%s); \
           admission registry stays empty, observe will return \
           Legacy_path (will retry on next tick)"
          msg
    | Ok json ->
        let registry, errors =
          Keeper_admission_registry.load_from_json json
        in
        List.iter
          (fun (e : Keeper_admission_registry.load_error) ->
            Log.Keeper.warn
              "RFC-0026 PR-E-1.6: admission policy parse failed for \
               keeper=%s"
              e.keeper_id)
          errors;
        let registered = Keeper_admission_registry.size registry in
        (* Install lookups via Atomic.set, then mark Done.  Order
           matters: a parallel fiber reading [policy_lookup] should
           never observe Done with the default [no_policy]. *)
        set_policy_lookup (fun id ->
          Keeper_admission_registry.lookup registry id);
        set_bucket_lookup (make_lazy_bucket_lookup ());
        mark_init_done ();
        Log.Keeper.info
          "RFC-0026 PR-E-1.6: admission runtime initialised \
           (policies=%d, errors=%d, base_path=%s)"
          registered (List.length errors) base_path
  end

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
    ~labels:[("keeper", keeper_id); ("outcome", outcome_label outcome)] ();
  outcome

let reset_for_test () =
  Stdlib.Mutex.protect init_mutex (fun () ->
    Atomic.set policy_lookup_ref no_policy;
    Atomic.set bucket_lookup_ref no_bucket;
    init_state := Idle)
