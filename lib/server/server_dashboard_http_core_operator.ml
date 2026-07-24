(** Operator broadcast + cache state cluster for dashboard HTTP core,
    extracted from server_dashboard_http_core.ml. *)

open Server_auth
open Server_dashboard_http_cache
open Dashboard_http_helpers

type operator_snapshot_publication =
  { epoch : string
  ; generation : int
  ; compute_sequence : int
  ; terminal_sequence : int
  ; json : Yojson.Safe.t
  ; has_success : bool
  }

type operator_snapshot_compute =
  { generation : int
  ; sequence : int
  }

(* --- Operator proactive refresh ---
   Default (no-param) requests are served from a background-refreshed ref.
   Parameterized requests fall back to on-demand compute with SWR cache.

   Using Proactive_refresh gives circuit breaker + exponential backoff on
   repeated failures, matching the pattern used by execution and mission loops.

   Interval: 10s (was 120s). Even if compute takes ~8s, the ref is updated
   every ~18s worst-case, which is acceptable for dashboard SSE polling. *)

(* Late-bound broadcast refs — set by server_dashboard_http.ml after
   Sse module is in scope.  Same pattern as _broadcast_workspace_truth_ref. *)
let operator_snapshot_broadcast_ref : (operator_snapshot_publication -> unit) ref =
  ref (fun (_publication : operator_snapshot_publication) -> ())
;;

let operator_digest_broadcast_ref : (Yojson.Safe.t -> unit) ref =
  ref (fun (_json : Yojson.Safe.t) -> ())
;;

let _operator_digest_broadcast_ref = operator_digest_broadcast_ref

let operator_snapshot_cache =
  let initializing_json () =
    `Assoc
      [ "status", `String "initializing"
      ; "generated_at", `String (Masc_domain.now_iso ())
      ]
  in
  create_cached_surface (initializing_json ())
;;

let operator_snapshot_cache_mu = Stdlib.Mutex.create ()

let operator_snapshot_cache_generation =
  Atomic.make 0
;;

let operator_snapshot_compute_sequence = Atomic.make 0
let operator_snapshot_published_sequence = ref 0
let operator_snapshot_terminal_sequence = ref 0

let operator_snapshot_epoch =
  (* NDT-OK: process-incarnation identity entropy only. *)
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string
;;

let initializing_operator_snapshot_json () =
  `Assoc
    [ "status", `String "initializing"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ]
;;

let synchronize_operator_snapshot_generation generation =
  let cached_generation = Atomic.get operator_snapshot_cache_generation in
  if not (Int.equal cached_generation generation)
  then (
    invalidate_cached_surface operator_snapshot_cache;
    operator_snapshot_cache.json <- initializing_operator_snapshot_json ();
    operator_snapshot_published_sequence := 0;
    operator_snapshot_terminal_sequence := 0;
    Atomic.set operator_snapshot_cache_generation generation)
;;

let operator_snapshot_publication () =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun generation ->
    Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
      synchronize_operator_snapshot_generation generation;
      { epoch = operator_snapshot_epoch
      ; generation
      ; compute_sequence = !operator_snapshot_published_sequence
      ; terminal_sequence = !operator_snapshot_terminal_sequence
      ; json = cached_surface_json operator_snapshot_cache
      ; has_success = cached_surface_has_success operator_snapshot_cache
      }))
;;

let operator_snapshot_publication_json publication =
  match publication.json with
  | `Assoc fields ->
    `Assoc
      (("snapshot_generation", `Int publication.generation)
       :: ("snapshot_epoch", `String publication.epoch)
       :: ("snapshot_compute_sequence", `Int publication.compute_sequence)
       :: ("snapshot_terminal_sequence", `Int publication.terminal_sequence)
       :: (fields
           |> List.remove_assoc "snapshot_generation"
           |> List.remove_assoc "snapshot_epoch"
           |> List.remove_assoc "snapshot_compute_sequence"
           |> List.remove_assoc "snapshot_terminal_sequence"))
  | json ->
    `Assoc
      [ "snapshot_epoch", `String publication.epoch
      ; "snapshot_generation", `Int publication.generation
      ; "snapshot_compute_sequence", `Int publication.compute_sequence
      ; "snapshot_terminal_sequence", `Int publication.terminal_sequence
      ; "payload", json
      ]
;;

let operator_snapshot_cache_diagnostics_json () =
  operator_snapshot_publication () |> operator_snapshot_publication_json
;;

let patch_operator_snapshot_cached_json patch =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun generation ->
    Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
      synchronize_operator_snapshot_generation generation;
      if cached_surface_has_success operator_snapshot_cache
      then
        operator_snapshot_cache.json
        <- patch (cached_surface_json operator_snapshot_cache)))
;;

let begin_operator_snapshot_compute () =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun generation ->
    Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
      synchronize_operator_snapshot_generation generation;
      mark_cached_surface_attempt operator_snapshot_cache;
      let sequence =
        Atomic.fetch_and_add operator_snapshot_compute_sequence 1 + 1
      in
      { generation; sequence }))
;;

let publish_operator_snapshot_if_current ~compute json =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun current ->
    if Int.equal current compute.generation
    then (
      Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
        synchronize_operator_snapshot_generation current;
        if compute.sequence > !operator_snapshot_terminal_sequence
        then (
          mark_cached_surface_success operator_snapshot_cache json;
          operator_snapshot_terminal_sequence := compute.sequence;
          operator_snapshot_published_sequence := compute.sequence;
          Atomic.set operator_snapshot_cache_generation compute.generation;
          Some
            { epoch = operator_snapshot_epoch
            ; generation = compute.generation
            ; compute_sequence = compute.sequence
            ; terminal_sequence = compute.sequence
            ; json = cached_surface_json operator_snapshot_cache
            ; has_success = true
            })
        else None))
    else None)
;;

let mark_operator_snapshot_error_if_current ~compute exn =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun current ->
    if Int.equal current compute.generation
    then
      Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
        synchronize_operator_snapshot_generation current;
        if compute.sequence > !operator_snapshot_terminal_sequence
        then (
          operator_snapshot_terminal_sequence := compute.sequence;
          mark_cached_surface_error operator_snapshot_cache exn;
          Some
            { epoch = operator_snapshot_epoch
            ; generation = compute.generation
            ; compute_sequence = !operator_snapshot_published_sequence
            ; terminal_sequence = compute.sequence
            ; json = cached_surface_json operator_snapshot_cache
            ; has_success = cached_surface_has_success operator_snapshot_cache
            })
        else None)
    else None)
;;

let operator_digest_cache =
  create_cached_surface
    (`Assoc
        [ "health", `String "initializing"
        ; "generated_at", `String (Masc_domain.now_iso ())
        ])
;;

let _operator_digest_cache = operator_digest_cache

let operator_refresh_interval_s =
  float_of_env_default
    "MASC_OPERATOR_REFRESH_INTERVAL_S"
    ~default:60.0
    ~min_v:10.0
    ~max_v:600.0
;;

let operator_snapshot_extra () =
  [ "readonly_pool", Workspace_utils.domain_local_pg_backend_diagnostics_json () ]
;;

module For_testing = struct
  let operator_snapshot_cache = operator_snapshot_cache
end
