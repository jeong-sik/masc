(** Catalog-aware variant of route → cascade name resolution.

    Split out of {!Cascade_routes} in the #19327/#19340 follow-up so that
    {!Cascade_routes} no longer depends on {!Cascade_catalog_runtime}.
    Keeping the dep in [Cascade_routes] closed a module-level cycle that
    transitively reached back to [Cascade_routes] through validate, leaving
    every cascade refactor since #19327 unable to build.

    Callers that need catalog validation (dashboard, doctor, runtime) use
    this module.  Callers that only need the configured route target
    without catalog cross-check use {!Cascade_routes} directly. *)

let cascade_name_for_use ?config_path (_use : Cascade_routes.logical_use) =
  (* B3: cascade routing 제거. use 별 route target 조회 / catalog validation /
     fallback 을 모두 걷어내고, default Runtime 의 binding id 를 그대로 돌려준다.
     (cascade→Runtime 비전: routes/cascade_name 간접은 의미 없음 — binding 하나가
     곧 하나의 Runtime, 소비자는 default Runtime 을 직접 쓴다.)
     default 미해결은 config 결함이므로 fail-fast — silent fallback 을 두지
     않는다(예전 route.<key> fallback 은 잘못된 default 를 조용히 숨겼다). *)
  match Runtime.default ?config_path () with
  | Ok rt -> rt.Runtime.id
  | Error msg ->
      failwith
        (Printf.sprintf "cascade_name_for_use: no default runtime resolved (%s)"
           msg)
