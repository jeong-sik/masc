(** Cascade-attempt persistence + fiber_unresolved enrichment.

    Extracted from keeper_registry.ml (lines 373-466) as part of the
    godfile decomp campaign. The 7 functions here form a self-contained
    cluster: read keeper runtime meta, update only the [last_cascade_attempt]
    slot via a focused [write_meta_with_merge] callback, and use the
    persisted attempt to enrich [fiber_unresolved] outcome labels with
    [provider=… http=…] suffixes (gated on freshness so stale slots
    from prior turns can't taint a new crash).

    Dependencies kept on Keeper_registry: only [get] (read-only lookup
    of in-memory entry for fallback when meta file read fails). No
    direct Atomic CAS path is required. *)

open Keeper_types
open Keeper_registry_types

let cascade_attempt_merge ~(latest : keeper_meta) ~(caller : keeper_meta) =
  { latest with
    meta_version = latest.meta_version
  ; runtime =
      { latest.runtime with
        last_cascade_attempt = caller.runtime.last_cascade_attempt
      }
  }
;;

let meta_for_cascade_attempt ~base_path ~keeper_name =
  let config = Coord.default_config base_path in
  match read_meta config keeper_name with
  | Ok (Some meta) -> Some (config, meta)
  | Ok None | Error _ ->
    (match Keeper_registry.get ~base_path keeper_name with
     | Some entry -> Some (config, entry.meta)
     | None -> None)
;;

let record ~base_path ~keeper_name attempt =
  try
    let keeper_name = String.trim keeper_name in
    if String.equal keeper_name ""
    then ()
    else
      match meta_for_cascade_attempt ~base_path ~keeper_name with
      | None -> ()
      | Some (config, meta) ->
        let caller =
          { meta with
            runtime = { meta.runtime with last_cascade_attempt = Some attempt }
          }
        in
        ignore
          (write_meta_with_merge
             ~merge:cascade_attempt_merge
             config
             caller
            : (unit, string) result)
  with
  | _ -> ()
;;

let suffix (attempt : cascade_attempt_record) =
  let http =
    match attempt.http_status with
    | Some status -> string_of_int status
    | None -> "none"
  in
  Printf.sprintf " provider=%s http=%s" attempt.provider_id http
;;

let last ~base_path ~keeper_name =
  let keeper_name = String.trim keeper_name in
  if String.equal keeper_name ""
  then None
  else
    try
      match meta_for_cascade_attempt ~base_path ~keeper_name with
      | Some (_config, meta) -> meta.runtime.last_cascade_attempt
      | None -> None
    with
    | _ -> None
;;

(* Stale provenance threshold: cascade attempts older than this are not
   attached to a fresh [fiber_unresolved] outcome (P1 review finding).
   Long enough to span a normal keeper turn cascade chain; short enough
   that a quiescent slot from a prior turn does not taint a new crash. *)
let freshness_threshold_sec = 120.0

let enrich_fiber_unresolved_outcome ~base_path ~keeper_name outcome =
  let fiber_unresolved = failure_reason_to_string Fiber_unresolved in
  if not (String.equal outcome fiber_unresolved)
  then outcome
  else
    match last ~base_path ~keeper_name with
    | None -> outcome
    | Some attempt ->
      (* P2 finding: only failure attempts explain a fiber_unresolved
         outcome. A persisted success would otherwise inherit
         [provider=... http=none] into a later failure label. *)
      (match attempt.outcome with
       | `Success -> outcome
       | `Failure _ ->
         (* P1 finding: gate enrichment on attempt freshness so a stale
            slot from an earlier turn cannot taint a new crash. NDT-OK:
            wall-clock comparison against persisted attempt timestamp. *)
         let age = Unix.gettimeofday () -. attempt.timestamp in
         if age > freshness_threshold_sec
         then outcome
         else outcome ^ suffix attempt)
;;
