(** Implementation: see [Cascade_preflight_state.mli] for surface docs.

    Closed sum types only — no catch-all branches in this file. *)

type reason =
  | Health_check_failed_repeatedly
  | Permanent_unhealthy
  | Transient_unhealthy
  | Rate_limited_long_window

type fingerprint = {
  tier_group : string;
  provider : string;
  reason : reason;
}

type record_outcome =
  [ `First
  | `Repeated of int
  | `Threshold_disable of int
  | `Already_disabled
  ]

let default_threshold = 5

(* Stable kebab-case slug for log interpolation and metric labels. *)
let reason_slug = function
  | Health_check_failed_repeatedly -> "health-check-failed-repeatedly"
  | Permanent_unhealthy -> "permanent-unhealthy"
  | Transient_unhealthy -> "transient-unhealthy"
  | Rate_limited_long_window -> "rate-limited-long-window"
;;

(* Owned metric names. Following the cascade_metrics.ml RFC-0043 pattern
   (module owns its constants; [Prometheus.ml]'s register_all() may mirror
   for /metrics endpoint registration later). *)
let metric_preflight_unhealthy_skip =
  "masc_cascade_preflight_unhealthy_skip_total"
;;

let metric_provider_disabled = "masc_cascade_provider_disabled_total"
let metric_provider_re_enabled = "masc_cascade_provider_re_enabled_total"

(* ── State ──────────────────────────────────────────────────────── *)

(* [Hashtbl] keyed by an opaque triple to avoid string interpolation
   collisions when tier_group or provider contain separators. *)
module Key = struct
  type t = fingerprint

  let equal (a : t) (b : t) =
    String.equal a.tier_group b.tier_group
    && String.equal a.provider b.provider
    && a.reason = b.reason
  ;;

  let hash (k : t) =
    Hashtbl.hash (k.tier_group, k.provider, reason_slug k.reason)
  ;;
end

module FpTbl = Hashtbl.Make (Key)

(* Per-provider disabled set membership — separate from fingerprint
   counts so [is_disabled] is O(1) without scanning all fingerprints. *)
module StrTbl = Hashtbl.Make (struct
  type t = string

  let equal = String.equal
  let hash = Hashtbl.seeded_hash 0
end)

type t = {
  counts : int FpTbl.t;
  disabled : unit StrTbl.t;
  mu : Stdlib.Mutex.t;
      (* Stdlib.Mutex selected per feedback_ocaml5-mutex-selection.md:
         cross-fiber, single-domain, no Eio effect dependency. The
         critical section is small (table lookup + counter bump). *)
  threshold : int;
}

let create ?(threshold = default_threshold) () =
  {
    counts = FpTbl.create 16;
    disabled = StrTbl.create 8;
    mu = Stdlib.Mutex.create ();
    threshold;
  }
;;

let global = create ()

let with_lock t f =
  Stdlib.Mutex.lock t.mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.mu) (fun () -> f ())
;;

(* ── Public API ─────────────────────────────────────────────────── *)

let record t ~tier_group ~provider ~reason : record_outcome =
  let fp = { tier_group; provider; reason } in
  with_lock t (fun () ->
    (* Always tick the per-call counter so dashboards see absolute
       skip volume (independent of disable transitions). *)
    Prometheus.inc_counter metric_preflight_unhealthy_skip
      ~labels:
        [ ("cascade", tier_group)
        ; ("provider", provider)
        ; ("reason", reason_slug reason)
        ]
      ();
    if StrTbl.mem t.disabled provider
    then `Already_disabled
    else (
      let prev = FpTbl.find_opt t.counts fp |> Option.value ~default:0 in
      let next = prev + 1 in
      FpTbl.replace t.counts fp next;
      if next = 1
      then `First
      else if next >= t.threshold
      then (
        StrTbl.replace t.disabled provider ();
        Prometheus.inc_counter metric_provider_disabled
          ~labels:
            [ ("cascade", tier_group)
            ; ("provider", provider)
            ; ("reason", reason_slug reason)
            ]
          ();
        `Threshold_disable next)
      else `Repeated next))
;;

let is_disabled t ~provider =
  with_lock t (fun () -> StrTbl.mem t.disabled provider)
;;

let reset_on_health_recovery t ~provider =
  with_lock t (fun () ->
    let was_disabled = StrTbl.mem t.disabled provider in
    StrTbl.remove t.disabled provider;
    (* Drop all fingerprints for this provider, regardless of reason. *)
    let stale_keys =
      FpTbl.fold
        (fun fp _count acc ->
          if String.equal fp.provider provider then fp :: acc else acc)
        t.counts
        []
    in
    List.iter (fun fp -> FpTbl.remove t.counts fp) stale_keys;
    if was_disabled
    then
      Prometheus.inc_counter metric_provider_re_enabled
        ~labels:[ ("provider", provider) ]
        ();
    was_disabled)
;;

let disabled_providers t =
  with_lock t (fun () ->
    StrTbl.fold (fun provider () acc -> provider :: acc) t.disabled [])
;;

let reset_for_test t =
  with_lock t (fun () ->
    FpTbl.reset t.counts;
    StrTbl.reset t.disabled)
;;
