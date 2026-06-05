(** Implementation: see [Keeper_preflight_health_tracker.mli] for surface docs.

    Closed sum types only — no catch-all branches in this file. *)

type reason =
  | Health_check_failed_repeatedly
  | Permanent_unhealthy
  | Transient_unhealthy
  | Rate_limited_long_window

type fingerprint = {
  runtime_id : string;
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

(** TTL in seconds after which a disabled provider is automatically
    re-enabled. Prevents permanent runtime death-spiral when the
    underlying issue (network blip, cold start, rate-limit window)
    resolves itself (GitHub #18502). *)
let disabled_ttl_seconds = 600.0

(* Stable kebab-case slug for log interpolation and metric labels. *)
let reason_slug = function
  | Health_check_failed_repeatedly -> "health-check-failed-repeatedly"
  | Permanent_unhealthy -> "permanent-unhealthy"
  | Transient_unhealthy -> "transient-unhealthy"
  | Rate_limited_long_window -> "rate-limited-long-window"
;;

(* Owned metric names. Following the runtime_metrics.ml RFC-0043 pattern
   (module owns its constants; [Otel_metric_store.ml]'s register_all() may mirror
   for /metrics endpoint registration later). *)
let metric_preflight_unhealthy_skip =
  "masc_runtime_preflight_unhealthy_skip_total"
;;

let metric_provider_disabled = "masc_runtime_provider_disabled_total"
let metric_provider_re_enabled = "masc_runtime_provider_re_enabled_total"

(* ── State ──────────────────────────────────────────────────────── *)

(* [Hashtbl] keyed by an opaque triple to avoid string interpolation
   collisions when runtime_id or provider contain separators. *)
module Key = struct
  type t = fingerprint

  let equal (a : t) (b : t) =
    String.equal a.runtime_id b.runtime_id
    && String.equal a.provider b.provider
    && a.reason = b.reason
  ;;

  let hash (k : t) =
    Hashtbl.hash (k.runtime_id, k.provider, reason_slug k.reason)
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
  disabled : (float * string) StrTbl.t;
      (** Maps provider → (disabled_at_timestamp, runtime_id).
          The timestamp enables TTL-based auto-expiry so providers
          don't stay disabled forever (GitHub #18502). *)
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

let record ?(clock = Time_compat.now) t ~runtime_id ~provider ~reason : record_outcome =
  let fp = { runtime_id; provider; reason } in
  with_lock t (fun () ->
    (* Always tick the per-call counter so dashboards see absolute
       skip volume (independent of disable transitions). *)
    Otel_metric_store.inc_counter metric_preflight_unhealthy_skip
      ~labels:
        [ ("runtime", runtime_id)
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
        StrTbl.replace t.disabled provider (clock (), runtime_id);
        Otel_metric_store.inc_counter metric_provider_disabled
          ~labels:
            [ ("runtime", runtime_id)
            ; ("provider", provider)
            ; ("reason", reason_slug reason)
            ]
          ();
        `Threshold_disable next)
      else `Repeated next))
;;

let is_disabled ?(clock = Time_compat.now) t ~provider =
  with_lock t (fun () ->
    match StrTbl.find_opt t.disabled provider with
    | None -> false
    | Some (disabled_at, _runtime_id) ->
      let age = clock () -. disabled_at in
      if age >= disabled_ttl_seconds
      then (
        (* Auto-expire: provider has been disabled long enough that the
           underlying issue may have resolved (GitHub #18502). *)
        StrTbl.remove t.disabled provider;
        (* Drop all fingerprints so next record starts from First. *)
        let stale_keys =
          FpTbl.fold
            (fun fp _count acc ->
              if String.equal fp.provider provider then fp :: acc else acc)
            t.counts
            []
        in
        List.iter (fun fp -> FpTbl.remove t.counts fp) stale_keys;
        Otel_metric_store.inc_counter metric_provider_re_enabled
          ~labels:[ ("provider", provider); ("reason", "ttl_auto_expire") ]
          ();
        false)
      else true)
;;

let reset_on_health_recovery t ~provider =
  with_lock t (fun () ->
    let was_disabled = Option.is_some (StrTbl.find_opt t.disabled provider) in
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
      Otel_metric_store.inc_counter metric_provider_re_enabled
        ~labels:[ ("provider", provider) ]
        ();
    was_disabled)
;;

let disabled_providers t =
  with_lock t (fun () ->
    StrTbl.fold (fun provider (_ts, _tg) acc -> provider :: acc) t.disabled [])
;;

let reset_for_test t =
  with_lock t (fun () ->
    FpTbl.reset t.counts;
    StrTbl.reset t.disabled)
;;
