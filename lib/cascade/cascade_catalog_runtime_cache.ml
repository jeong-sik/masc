(* Stage 08 — cache layer + shared type definitions for the
   cascade catalog runtime.  These types and the singleton cache live
   in a dedicated module so the validate/probe/json/resolve submodules
   can share them without duplicating record definitions or pulling in
   the full facade.  The parent [Cascade_catalog_runtime] re-exports
   every type below transparently so caller field/constructor access
   remains source-compatible. *)

type candidate_probe_status =
  | Probe_ok
  | Probe_skipped of string
  | Probe_not_applicable of string
  | Probe_error of string

let probe_timeout_sec = 5.0

type candidate_probe = {
  model_string : string;
  provider_kind : string;
  model_id : string;
  base_url : string;
  status : candidate_probe_status;
}

type candidate_runtime = {
  model_string : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

(* [profile_build] is the validated profile shape. Provider liveness remains
   advisory and never rejects a catalog, but the runtime snapshot carries the
   latest probe evidence observed during validation. *)
type profile_build = {
  name : string;
  weighted_entries : Cascade_config_loader.weighted_entry list;
  inference_params : Cascade_config_loader.inference_params;
  api_key_env_overrides : (string * string) list;
  strategy : Cascade_strategy.t;
  ollama_max_concurrent : int option;
  cli_max_concurrent : int option;
  candidates : candidate_runtime list;
  probes : candidate_probe list;
  required_capability_profile : string option;
}

type profile_snapshot = profile_build

type snapshot = {
  source_path : string;
  mtime : float;
  validated_at : float;
  profiles : profile_snapshot list;
  default_profile_name : string;
}

type profile_rejection = {
  name : string;
  errors : string list;
  probes : candidate_probe list;
}

type rejection = {
  source_path : string;
  attempted_mtime : float option;
  checked_at : float;
  errors : string list;
  profiles : profile_rejection list;
}

type state =
  | Validated of snapshot
  | Validated_with_rejections of {
      snapshot : snapshot;
      rejected_update : rejection;
    }
  | Serving_last_known_good of {
      snapshot : snapshot;
      rejected_update : rejection;
    }

type validation_result = {
  snapshot : snapshot;
  rejected_update : rejection option;
}

type cache = {
  active_snapshot : snapshot option;
  rejected_update : rejection option;
}

(* Singleton cache.  Validate/resolve coordinate through this same mutable
   slot — splitting it across modules would break the last-known-good
   contract on hot reload. *)
let cache = ref { active_snapshot = None; rejected_update = None }
let cache_mu = Mutex.create ()

let with_cache_lock f =
  Mutex.lock cache_mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock cache_mu) f

let reset_cache_for_tests () =
  with_cache_lock (fun () ->
      cache := { active_snapshot = None; rejected_update = None })

let invalidate_path config_path =
  let keep_snapshot = function
    | Some (snapshot : snapshot)
      when String.equal snapshot.source_path config_path ->
        None
    | other -> other
  in
  let keep_rejection = function
    | Some (rejection : rejection)
      when String.equal rejection.source_path config_path ->
        None
    | other -> other
  in
  with_cache_lock (fun () ->
      let current = !cache in
      cache :=
        {
          active_snapshot = keep_snapshot current.active_snapshot;
          rejected_update = keep_rejection current.rejected_update;
        })

let install_snapshot_for_tests ~source_path ~profile_names =
  let mtime =
    try (Unix.stat source_path).Unix.st_mtime with
    | Unix.Unix_error _ | Sys_error _ -> 0.0
  in
  let profiles : profile_snapshot list =
    profile_names
    |> List.sort_uniq String.compare
    |> List.map (fun name ->
           {
             name;
             weighted_entries = [];
             inference_params =
               {
                 temperature = None;
                 max_tokens = None;
                 keep_alive = None;
                 num_ctx = None;
                 thinking_enabled = None;
                 thinking_budget = None;
               };
             api_key_env_overrides = [];
             strategy = Cascade_strategy.failover;
             ollama_max_concurrent = None;
             cli_max_concurrent = None;
             candidates = [];
             probes = [];
             required_capability_profile = None;
           })
  in
  let snapshot =
    {
      source_path;
      mtime;
      validated_at = Unix.gettimeofday ();
      profiles;
      (* Test helper does not exercise default-profile resolution; an
         empty string keeps the snapshot well-typed while preserving
         the helper's "install these profile names verbatim" contract.
         Field added by RFC-0066 Phase 1 (PR #14652). *)
      default_profile_name = "";
    }
  in
  with_cache_lock (fun () ->
      cache := { active_snapshot = Some snapshot; rejected_update = None })

(* Shared helpers used by both validate (when looking up active mtime) and
   resolve (when reconciling cached snapshots against the on-disk source). *)
let same_snapshot_key (snapshot : snapshot) ~path ~mtime =
  String.equal snapshot.source_path path && Float.equal snapshot.mtime mtime

let same_rejection_key (rejection : rejection) ~path ~mtime =
  String.equal rejection.source_path path
  &&
  match rejection.attempted_mtime with
  | Some rejection_mtime -> Float.equal rejection_mtime mtime
  | None -> false

let profile_lookup profiles name =
  List.find_opt
    (fun (profile : profile_snapshot) -> String.equal profile.name name)
    profiles

let profile_names_of_snapshot (snapshot : snapshot) =
  List.map (fun (profile : profile_snapshot) -> profile.name) snapshot.profiles
