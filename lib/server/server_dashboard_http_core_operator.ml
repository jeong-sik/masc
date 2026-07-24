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
  ; fresh_until_unix : float option
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
let operator_snapshot_compute_sequence = Atomic.make 0

let operator_snapshot_epoch =
  (* NDT-OK: process-incarnation identity entropy only. *)
  Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string
;;

let invalidated_operator_snapshot_json () =
  `Assoc
    [ "status", `String "invalidated"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ]
;;

let make_operator_snapshot_publication
      ~generation
      ~compute_sequence
      ~terminal_sequence
      ~fresh_until_unix
  =
  { epoch = operator_snapshot_epoch
  ; generation
  ; compute_sequence
  ; terminal_sequence
  ; fresh_until_unix
  ; json = cached_surface_json operator_snapshot_cache
  ; has_success = cached_surface_has_success operator_snapshot_cache
  }
;;

(* The publication record is immutable and replaced only while
   [operator_snapshot_cache_mu] is held. Cache diagnostics are frozen into the
   record at a terminal transition, so one identity never acquires a second
   JSON value merely because wall time advanced. *)
let operator_snapshot_publication_ref =
  ref
    (make_operator_snapshot_publication
       ~generation:0
       ~compute_sequence:0
       ~terminal_sequence:0
       ~fresh_until_unix:None)
;;

let install_operator_snapshot_invalidation generation =
  invalidate_cached_surface operator_snapshot_cache;
  operator_snapshot_cache.json <- invalidated_operator_snapshot_json ();
  let publication =
    make_operator_snapshot_publication
      ~generation
      ~compute_sequence:0
      ~terminal_sequence:0
      ~fresh_until_unix:None
  in
  operator_snapshot_publication_ref := publication;
  publication
;;

let synchronize_operator_snapshot_generation generation =
  let publication = !operator_snapshot_publication_ref in
  if generation > publication.generation
  then install_operator_snapshot_invalidation generation
  else publication
;;

let read_operator_snapshot_publication f =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun generation ->
    Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
      synchronize_operator_snapshot_generation generation |> f))
;;

let operator_snapshot_publication () =
  read_operator_snapshot_publication Fun.id
;;

let operator_snapshot_publication_with_freshness () =
  read_operator_snapshot_publication (fun publication ->
    let is_fresh =
      publication.has_success
      &&
      match publication.fresh_until_unix with
      | Some deadline -> Time_compat.now () < deadline
      | None -> false
    in
    publication, is_fresh)
;;

let operator_snapshot_publication_json
      (publication : operator_snapshot_publication)
  =
  let fresh_until_json =
    match publication.fresh_until_unix with
    | Some value -> `Float value
    | None -> `Null
  in
  match publication.json with
  | `Assoc fields ->
    `Assoc
      (("snapshot_generation", `Int publication.generation)
       :: ("snapshot_epoch", `String publication.epoch)
       :: ("snapshot_compute_sequence", `Int publication.compute_sequence)
       :: ("snapshot_terminal_sequence", `Int publication.terminal_sequence)
       :: ("snapshot_fresh_until_unix", fresh_until_json)
       :: (fields
           |> List.remove_assoc "snapshot_generation"
           |> List.remove_assoc "snapshot_epoch"
           |> List.remove_assoc "snapshot_compute_sequence"
           |> List.remove_assoc "snapshot_terminal_sequence"
           |> List.remove_assoc "snapshot_fresh_until_unix"))
  | json ->
    `Assoc
      [ "snapshot_epoch", `String publication.epoch
      ; "snapshot_generation", `Int publication.generation
      ; "snapshot_compute_sequence", `Int publication.compute_sequence
      ; "snapshot_terminal_sequence", `Int publication.terminal_sequence
      ; "snapshot_fresh_until_unix", fresh_until_json
      ; "payload", json
      ]
;;

let operator_snapshot_cache_diagnostics_json () =
  operator_snapshot_publication () |> operator_snapshot_publication_json
;;

let publish_operator_snapshot_invalidation_if_current ~generation =
  Dashboard_projection_cache.with_snapshot_publication_generation
    (fun current_generation ->
       if not (Int.equal generation current_generation)
       then None
       else
         Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
           let publication =
             synchronize_operator_snapshot_generation current_generation
           in
           if not (Int.equal publication.generation generation)
              || publication.has_success
              || publication.terminal_sequence > 0
           then None
           else Some publication))
;;

let begin_operator_snapshot_compute () =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun generation ->
    Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
      ignore
        (synchronize_operator_snapshot_generation generation
         : operator_snapshot_publication);
      mark_cached_surface_attempt operator_snapshot_cache;
      let sequence =
        Atomic.fetch_and_add operator_snapshot_compute_sequence 1 + 1
      in
      { generation; sequence }))
;;

let operator_snapshot_freshness_ttl_s =
  Server_dashboard_http_core_cache.standard_cache_ttl_s
;;

let publish_operator_snapshot_if_current_with_freshness
      ~compute
      ~fresh_for_s
      json
  =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun current ->
    if Int.equal current compute.generation
    then (
      Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
        let publication = synchronize_operator_snapshot_generation current in
        if Int.equal publication.generation compute.generation
           && compute.sequence > publication.terminal_sequence
        then (
          mark_cached_surface_success operator_snapshot_cache json;
          let published =
            make_operator_snapshot_publication
              ~generation:compute.generation
              ~compute_sequence:compute.sequence
              ~terminal_sequence:compute.sequence
              ~fresh_until_unix:(Some (Time_compat.now () +. fresh_for_s))
          in
          operator_snapshot_publication_ref := published;
          Some published)
        else None))
    else None)
;;

let publish_operator_snapshot_if_current ~compute json =
  publish_operator_snapshot_if_current_with_freshness
    ~compute
    ~fresh_for_s:operator_snapshot_freshness_ttl_s
    json
;;

let mark_operator_snapshot_error_if_current ~compute exn =
  Dashboard_projection_cache.with_snapshot_publication_generation (fun current ->
    if Int.equal current compute.generation
    then
      Stdlib.Mutex.protect operator_snapshot_cache_mu (fun () ->
        let publication = synchronize_operator_snapshot_generation current in
        if Int.equal publication.generation compute.generation
           && compute.sequence > publication.terminal_sequence
        then (
          mark_cached_surface_error operator_snapshot_cache exn;
          let terminal =
            let fresh_until_unix =
              Option.map
                (fun deadline -> Float.min deadline (Time_compat.now ()))
                publication.fresh_until_unix
            in
            make_operator_snapshot_publication
              ~generation:compute.generation
              ~compute_sequence:publication.compute_sequence
              ~terminal_sequence:compute.sequence
              ~fresh_until_unix
          in
          operator_snapshot_publication_ref := terminal;
          Some terminal)
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
  let publish_operator_snapshot_success ?(fresh_for_s = operator_snapshot_freshness_ttl_s) json =
    let compute = begin_operator_snapshot_compute () in
    publish_operator_snapshot_if_current_with_freshness
      ~compute
      ~fresh_for_s
      json
end
