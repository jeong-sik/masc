(** Catalog-aware variant of route → cascade name resolution.

    Split out of {!Cascade_routes} in the #19327/#19340 follow-up so that
    {!Cascade_routes} no longer depends on {!Cascade_catalog_runtime}.
    Keeping the dep in [Cascade_routes] closed a module-level cycle that
    transitively reached back to [Cascade_routes] through validate, leaving
    every cascade refactor since #19327 unable to build.

    Callers that need catalog validation (dashboard, doctor, runtime) use
    this module.  Callers that only need the configured route target
    without catalog cross-check use {!Cascade_routes} directly. *)

let cascade_name_for_use ?config_path use =
  let route_key = Cascade_routes.logical_use_key use in
  let route_target =
    Cascade_routes.configured_route_bindings ?config_path ()
    |> List.find_map (fun (key, target) ->
           if String.equal key route_key then Some target else None)
  in
  let catalog_names =
    match Cascade_catalog_runtime.known_profile_names () with
    | Ok names -> names
    | Error _ -> []
  in
  let fallback =
    Cascade_routes.fallback_name_for_catalog use ~catalog:catalog_names
  in
  match route_target with
  | Some target when catalog_names = [] ->
      Cascade_metrics.on_route_resolve_fallback ~reason:"catalog_unvalidated";
      Cascade_routes.warn_unvalidated_route_target_once ~route_key ~target
        ~fallback;
      target
  | Some target when List.mem target catalog_names -> target
  | Some target ->
      Cascade_metrics.on_route_resolve_fallback
        ~reason:"target_not_in_catalog";
      Cascade_routes.warn_invalid_route_target_once ~route_key ~target
        ~fallback;
      fallback
  | None -> fallback
