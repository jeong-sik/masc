(* Stage 08 — runtime resolution orchestration.  This module owns
   [inspect_active] (the cache-aware boot-time hand-off between
   validate, LKG, and recovery) and the per-cascade-name lookup
   ([lookup_active_profile], [resolve_declared_name],
   [models_of_cascade_name]).  Named-provider resolution and scalar
   profile getters live in [Cascade_catalog_runtime_named_providers]
   on top of the [lookup_active_profile] entry point exported here. *)

open Cascade_catalog_runtime_cache
module Validate = Cascade_catalog_runtime_validate

let config_path_opt = Validate.config_path_opt

let inspect_active ?sw ?net ?clock () =
  let (_ : float Eio.Time.clock_ty Eio.Resource.t option) = clock in
  match config_path_opt () with
  | None ->
      let checked_at = Unix.gettimeofday () in
      let rejection =
        {
          source_path = "(unresolved)";
          attempted_mtime = None;
          checked_at;
          errors = [ "active cascade catalog path could not be resolved" ];
          profiles = [];
        }
      in
      (* Capture prev rejected_update state inside the same lock as
         the cache write so transition detection (None -> Some) is
         race-safe. *)
      let outcome =
        with_cache_lock (fun () ->
            match !cache.active_snapshot with
            | Some snapshot ->
                let prev_was_failing =
                  Option.is_some !cache.rejected_update
                in
                cache :=
                  {
                    active_snapshot = Some snapshot;
                    rejected_update = Some rejection;
                  };
                `Lkg (snapshot, prev_was_failing)
            | None -> `Fail)
      in
      (match outcome with
       | `Lkg (snapshot, prev_was_failing) ->
         Cascade_metrics.on_serving_last_known_good
           ~reason:"path_unresolved";
         if not prev_was_failing then
           Log.Misc.warn
             "[CascadeCatalog] entering Serving_last_known_good: cascade \
              path could not be resolved; continuing on cached snapshot \
              until env/.masc/config layout is fixed";
         Ok (Serving_last_known_good { snapshot; rejected_update = rejection })
       | `Fail -> Error rejection)
  | Some config_path ->
      let source_state = Validate.active_source_state ~config_path in
      let source_path = source_state.info.source_path in
      let current_mtime = source_state.source_mtime in
      let cached_result =
        with_cache_lock (fun () ->
            match
              ( !cache.active_snapshot,
                !cache.rejected_update,
                current_mtime )
            with
            | Some snapshot, Some rejection, Some mtime
              when same_snapshot_key snapshot ~path:source_path ~mtime
                   && same_rejection_key rejection ~path:source_path
                        ~mtime ->
                Some
                  (Ok
                     (Validated_with_rejections
                        { snapshot; rejected_update = rejection }))
            | Some snapshot, _, Some mtime
              when same_snapshot_key snapshot ~path:source_path ~mtime ->
                Some (Ok (Validated snapshot))
            | Some snapshot, Some rejection, Some mtime
              when same_rejection_key rejection ~path:source_path ~mtime ->
                Some
                  (Ok
                     (Serving_last_known_good
                        { snapshot; rejected_update = rejection }))
            | None, Some rejection, Some mtime
              when same_rejection_key rejection ~path:source_path ~mtime ->
                Some (Error rejection)
            | _ -> None)
      in
      match cached_result with
      | Some result ->
          (match result with
           | Ok (Serving_last_known_good _) ->
             (* Same-mtime replay of a previously-cached rejection.
                Steady-state while the operator hasn't fixed the
                fault — counter ticks but no log noise. *)
             Cascade_metrics.on_serving_last_known_good
               ~reason:"stale_rejection_cached"
           | Ok (Validated_with_rejections _) ->
             (* Same-mtime replay of a previously-cached partial
                rejection.  Steady-state while the operator hasn't
                fixed the rejected subset — counter ticks but no
                log noise. *)
             Cascade_metrics.on_validated_with_rejections
               ~reason:"stale_partial_rejection_cached"
           | _ -> ());
          result
      | None -> (
          match Validate.validate_path_result ?sw ?net ~config_path () with
          | Ok { snapshot; rejected_update = None } ->
              (* Recovery detection: capture prev rejected_update
                 inside the same lock as the write so a degraded ->
                 Validated transition is detected atomically.  The
                 condition catches BOTH the LKG -> Validated case
                 (iter 5) and the Validated_with_rejections ->
                 Validated case (iter 11) since both store the
                 prev state as [rejected_update = Some _]. *)
              let recovered =
                with_cache_lock (fun () ->
                    let prev_was_failing =
                      Option.is_some !cache.rejected_update
                    in
                    cache :=
                      {
                        active_snapshot = Some snapshot;
                        rejected_update = None;
                      };
                    prev_was_failing)
              in
              if recovered then (
                Cascade_metrics.on_degraded_recovery ();
                Log.Misc.info
                  "[CascadeCatalog] cascade.toml degraded state cleared; \
                   transitioning back to Validated");
              Ok (Validated snapshot)
          | Ok { snapshot; rejected_update = Some rejection } ->
              (* Capture prev cache state inside the same lock as
                 the write so the [Validated -> Validated_with_rejections]
                 transition is detected atomically (mirrors the LKG
                 entry pattern in iter 5).  [prev_was_failing] is true
                 if the previous state was already partial OR fully
                 failing (LKG); the WARN below fires only on the
                 clean -> partial transition. *)
              let prev_was_failing =
                with_cache_lock (fun () ->
                    let prev = Option.is_some !cache.rejected_update in
                    cache :=
                      {
                        active_snapshot = Some snapshot;
                        rejected_update = Some rejection;
                      };
                    prev)
              in
              Cascade_metrics.on_validated_with_rejections
                ~reason:"fresh_partial_rejection";
              if not prev_was_failing then
                Log.Misc.warn
                  "[CascadeCatalog] entering Validated_with_rejections: \
                   %d profile(s) rejected (%s); cascade serves the \
                   validated subset, operator should check newly-added \
                   profiles"
                  (List.length rejection.profiles)
                  (String.concat "; " rejection.errors);
              Ok
                (Validated_with_rejections
                   { snapshot; rejected_update = rejection })
          | Error rejection ->
              let outcome =
                with_cache_lock (fun () ->
                    match !cache.active_snapshot with
                    | Some snapshot ->
                        let prev_was_failing =
                          Option.is_some !cache.rejected_update
                        in
                        cache :=
                          {
                            active_snapshot = Some snapshot;
                            rejected_update = Some rejection;
                          };
                        `Lkg (snapshot, prev_was_failing)
                    | None ->
                        cache :=
                          {
                            active_snapshot = None;
                            rejected_update = Some rejection;
                          };
                        `Fail)
              in
              (match outcome with
               | `Lkg (snapshot, prev_was_failing) ->
                 Cascade_metrics.on_serving_last_known_good
                   ~reason:"validation_failed";
                 if not prev_was_failing then
                   Log.Misc.warn
                     "[CascadeCatalog] entering Serving_last_known_good: \
                      validation failed (%s); continuing on cached \
                      snapshot until cascade.toml is fixed"
                     (String.concat "; " rejection.errors);
                 Ok
                   (Serving_last_known_good
                      { snapshot; rejected_update = rejection })
               | `Fail -> Error rejection))

let require_snapshot ?sw ?net ?clock () =
  match inspect_active ?sw ?net ?clock () with
  | Ok (Validated snapshot) -> Ok snapshot
  | Ok (Validated_with_rejections { snapshot; _ }) -> Ok snapshot
  | Ok (Serving_last_known_good { snapshot; _ }) -> Ok snapshot
  | Error rejection ->
      let detail =
        if rejection.errors = [] then "active catalog validation failed"
        else String.concat "; " rejection.errors
      in
      Error detail

(* RFC-0066 cycle break: inlined the
   [Keeper_cascade_profile.normalize_declared_name] body to avoid the
   [Keeper_cascade_profile  Cascade_catalog_runtime
   Keeper_cascade_profile] cycle that RFC-0066 Phase 1 (PR #14652)
   completed by routing [catalog_names] through this module.

   The body uses only [Cascade_routes] primitives, which this module
   already depends on (see [Cascade_routes.configured_route_targets]
   above), so inlining here is dependency-neutral. *)
let normalize_declared_name (raw : string) : string =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then
    Cascade_routes.cascade_name_for_use Cascade_routes.Keeper_turn
  else
    match Cascade_routes.logical_use_of_string_opt trimmed with
    | Some use -> Cascade_routes.cascade_name_for_use use
    | None -> trimmed

let lookup_active_profile ?sw ?net ?clock raw_name =
  match require_snapshot ?sw ?net ?clock () with
  | Error _ as e -> e
  | Ok snapshot -> (
      let trimmed = String.trim raw_name in
      if String.equal trimmed "" then
        (* RFC-0066 Phase 1: blank raw means "the active default cascade".
           Resolve via the snapshot's [default_profile_name], which the
           validator builds from [Cascade_routes.cascade_name_for_use
           Keeper_turn] and guarantees is present in [profiles]
           (snapshot construction rejects otherwise).  Reading
           [List.hd snapshot.profiles] would silently return the
           lexicographically-first profile because [discover_profiles]
           sorts via [List.sort_uniq String.compare]. *)
        match
          profile_lookup snapshot.profiles snapshot.default_profile_name
        with
        | Some profile ->
            Ok (snapshot, snapshot.default_profile_name, profile)
        | None -> (
            (* Validator invariant violation; stay defensive. *)
            match snapshot.profiles with
            | first :: _ -> Ok (snapshot, first.name, first)
            | [] ->
                Error
                  "snapshot has no profiles; cannot resolve blank \
                   cascade name")
      else
        let normalized =
          match
            [ trimmed; "tier-group." ^ trimmed; "tier." ^ trimmed ]
            |> List.find_opt (fun candidate ->
                   Option.is_some
                     (profile_lookup snapshot.profiles candidate))
          with
          | Some candidate -> candidate
          | None -> normalize_declared_name raw_name
        in
        match profile_lookup snapshot.profiles normalized with
        | Some profile -> Ok (snapshot, normalized, profile)
        | None ->
            let known =
              profile_names_of_snapshot snapshot |> String.concat ", "
            in
            Error
              (Printf.sprintf
                 "unknown cascade_name %S (active profiles: %s)" normalized
                 known))

let resolve_declared_name ?sw ?net ?clock ~raw_name () =
  match lookup_active_profile ?sw ?net ?clock raw_name with
  | Ok (_snapshot, normalized, _profile) -> Ok normalized
  | Error _ as e -> e

let expand_weighted_entries ~cascade
    (entries : Cascade_config_loader.weighted_entry list) :
    Cascade_config_loader.weighted_entry list =
  let input_count = List.length entries in
  let expanded =
    List.concat_map
      (fun (entry : Cascade_config_loader.weighted_entry) ->
        Cascade_config.expand_auto_models [ entry.model ]
        |> List.map (fun model -> { entry with model }))
      entries
  in
  let output_count = List.length expanded in
  Cascade_metrics.on_auto_expansion_fanout ~cascade
    ~fanout:(output_count - input_count);
  expanded

let models_of_cascade_name ?sw ?net ?clock raw_name =
  match lookup_active_profile ?sw ?net ?clock raw_name with
  | Error _ as e -> e
  | Ok (_snapshot, normalized, profile) ->
      Ok
        (expand_weighted_entries ~cascade:normalized profile.weighted_entries
        |> List.map (fun (entry : Cascade_config_loader.weighted_entry) ->
               entry.model))

let known_profile_names ?sw ?net ?clock () =
  match require_snapshot ?sw ?net ?clock () with
  | Ok snapshot -> Ok (profile_names_of_snapshot snapshot)
  | Error _ as e -> e

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if value = "" || Hashtbl.mem seen value then false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let invalid_profile_errors ?sw ?net ?clock () =
  let of_rejection rejection =
    rejection.profiles
    |> List.filter_map (fun (profile : profile_rejection) ->
           let errors = dedupe_keep_order profile.errors in
           if errors = [] then None else Some (profile.name, errors))
  in
  match inspect_active ?sw ?net ?clock () with
  | Ok (Validated _) -> []
  | Ok (Validated_with_rejections { rejected_update; _ })
  | Ok (Serving_last_known_good { rejected_update; _ })
  | Error rejected_update ->
      of_rejection rejected_update
