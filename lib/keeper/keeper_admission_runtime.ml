(* See keeper_admission_runtime.mli for documentation. *)

let no_policy : Keeper_admission_glue.policy_lookup = fun _ -> None
let no_bucket : Keeper_admission_router.bucket_lookup = fun _ -> None

let policy_lookup_ref : Keeper_admission_glue.policy_lookup ref = ref no_policy
let bucket_lookup_ref : Keeper_admission_router.bucket_lookup ref = ref no_bucket

let init_mutex = Stdlib.Mutex.create ()
let init_done = ref false

let set_policy_lookup f = policy_lookup_ref := f
let set_bucket_lookup f = bucket_lookup_ref := f

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

let init_once_from_base_path ~base_path =
  Stdlib.Mutex.protect init_mutex (fun () ->
    if !init_done then ()
    else begin
      init_done := true;
      let cascade_json_path =
        Filename.concat (Filename.concat base_path ".masc/config")
          "cascade.json"
      in
      match Cascade_config_loader.load_json cascade_json_path with
      | Error msg ->
          Log.Keeper.warn
            "RFC-0026 PR-E-1.6: cascade.json load failed (%s); \
             admission registry stays empty, observe will return \
             Legacy_path"
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
          set_policy_lookup (fun id ->
            Keeper_admission_registry.lookup registry id);
          set_bucket_lookup (make_lazy_bucket_lookup ());
          Log.Keeper.info
            "RFC-0026 PR-E-1.6: admission runtime initialised \
             (policies=%d, errors=%d, base_path=%s)"
            registered (List.length errors) base_path
    end)

let policy_lookup keeper_id = !policy_lookup_ref keeper_id
let bucket_lookup provider = !bucket_lookup_ref provider

let outcome_label (outcome : Keeper_admission_glue.outcome) : string =
  match outcome with
  | Keeper_admission_glue.Legacy_path -> "legacy"
  | Keeper_admission_glue.New_admission decision ->
      (match decision with
       | Keeper_admission_router.Dispatch _ -> "dispatch"
       | Keeper_admission_router.Wait -> "wait"
       | Keeper_admission_router.Surface _ -> "surface")

let observe ~keeper_id =
  let outcome =
    Keeper_admission_glue.decide
      ~keeper_id
      ~policies:policy_lookup
      ~buckets:bucket_lookup
  in
  Prometheus.inc_counter
    Prometheus.metric_keeper_admission_shadow_outcome
    ~labels:[("keeper", keeper_id); ("outcome", outcome_label outcome)] ();
  outcome

let reset_for_test () =
  Stdlib.Mutex.protect init_mutex (fun () ->
    policy_lookup_ref := no_policy;
    bucket_lookup_ref := no_bucket;
    init_done := false)
