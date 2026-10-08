(** Server_dashboard_http_cache — cached_surface type and cache lifecycle. *)

type surface_snapshot = {
  json : Yojson.Safe.t;
  last_success_unix : float option;
  last_attempt_unix : float option;
  last_error : string option;
  last_error_unix : float option;
}

type cached_surface_payload = {
  json : Yojson.Safe.t;
  raw_json : string;
  etag : string;
}

type publication = {
  current : surface_snapshot;
  memoized_payload : cached_surface_payload option;
}

type cached_surface = publication Atomic.t

let snapshot surface = (Atomic.get surface).current

let rec update_cached_surface surface transform =
  let previous = Atomic.get surface in
  let next = { current = transform previous.current; memoized_payload = None } in
  if not (Atomic.compare_and_set surface previous next) then
    update_cached_surface surface transform

let create_cached_surface json =
  Atomic.make {
    current =
      {
        json;
        last_success_unix = None;
        last_attempt_unix = None;
        last_error = None;
        last_error_unix = None;
      };
    memoized_payload = None;
  }

let now_cache_stamp () =
  let ts = Unix.gettimeofday () in
  ts


let mark_cached_surface_attempt surface =
  let ts = now_cache_stamp () in
  update_cached_surface surface (fun current ->
    { current with last_attempt_unix = Some ts })

let mark_cached_surface_success surface json =
  let ts = now_cache_stamp () in
  update_cached_surface surface (fun current ->
    { current with
      json
    ; last_success_unix = Some ts
    ; last_error = None
    ; last_error_unix = None
    })

let mark_cached_surface_error_message surface message =
  let ts = now_cache_stamp () in
  update_cached_surface surface (fun current ->
    { current with
      last_error = Some message
    ; last_error_unix = Some ts
    })

let mark_cached_surface_error surface exn =
  mark_cached_surface_error_message surface (Printexc.to_string exn)
;;

let invalidate_cached_surface ?json surface =
  update_cached_surface surface (fun current ->
    { json = (match json with Some json -> json | None -> current.json)
    ; last_success_unix = None
    ; last_attempt_unix = None
    ; last_error = None
    ; last_error_unix = None
    })

let upsert_assoc_field key value fields =
  (key, value) :: List.filter (fun (existing, _) -> not (String.equal key existing)) fields

let extend_projection_diagnostics json extra_fields =
  match json with
  | `Assoc fields ->
      let existing =
        match List.assoc_opt "projection_diagnostics" fields with
        | Some (`Assoc diagnostics) -> diagnostics
        | _ -> []
      in
      let merged =
        List.fold_left
          (fun fields (key, value) -> upsert_assoc_field key value fields)
          existing extra_fields
      in
      `Assoc
        (upsert_assoc_field "projection_diagnostics" (`Assoc merged)
           fields)
  | other -> other

let surface_snapshot_json ~now surface =
  let iso_json timestamp =
    Json_util.string_opt_to_json
      (Option.map Masc_domain.iso8601_of_unix_seconds timestamp)
  in
  let cache_state, stale_reason, stale_age_ms =
    match surface.last_success_unix, surface.last_error_unix with
    | None, _ -> ("initializing", surface.last_error, None)
    | Some success_ts, Some error_ts when error_ts > success_ts ->
        ( "stale",
          surface.last_error,
          Some (int_of_float ((now -. success_ts) *. 1000.0)) )
    | Some _, _ -> ("fresh", None, None)
  in
  extend_projection_diagnostics surface.json
    [
      ("cache_state", `String cache_state);
      ("last_success_at", iso_json surface.last_success_unix);
      ("last_attempt_at", iso_json surface.last_attempt_unix);
      ("last_error_at", iso_json surface.last_error_unix);
      ("stale_reason", Json_util.string_opt_to_json stale_reason);
      ( "stale_age_ms", Json_util.int_opt_to_json stale_age_ms );
    ]

let cached_surface_json cache =
  surface_snapshot_json ~now:(Unix.gettimeofday ()) (snapshot cache)

let cached_surface_has_success cache =
  Option.is_some (snapshot cache).last_success_unix

let cached_surface_payload cache =
  let publication = Atomic.get cache in
  let surface = publication.current in
  let is_stale =
    match surface.last_success_unix, surface.last_error_unix with
    | Some success_ts, Some error_ts -> error_ts > success_ts
    | _ -> false
  in
  match publication.memoized_payload with
  | Some payload when not is_stale ->
      payload
  | _ ->
      let json = surface_snapshot_json ~now:(Unix.gettimeofday ()) surface in
      let raw_json = Yojson.Safe.to_string json in
      let etag = Http_server_eio.Response.weak_etag_value raw_json in
      let payload = { json; raw_json; etag } in
      if not is_stale then
        ignore (Atomic.compare_and_set cache publication
          { publication with memoized_payload = Some payload });
      payload

let cached_surface_or_first_success_payload surface ~cache_key ~ttl ~clock
    ~timeout_sec compute =
  if cached_surface_has_success surface then
    cached_surface_payload surface
  else
    let compute_and_track () =
      mark_cached_surface_attempt surface;
      try
        let json = compute () in
        mark_cached_surface_success surface json;
        json
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          mark_cached_surface_error surface exn;
          raise exn
    in
    let _ =
      Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl ~clock
        ~timeout_sec compute_and_track
    in
    cached_surface_payload surface

let cached_surface_or_first_success_json surface ~cache_key ~ttl ~clock
    ~timeout_sec compute =
  (cached_surface_or_first_success_payload surface ~cache_key ~ttl ~clock
     ~timeout_sec compute).json
