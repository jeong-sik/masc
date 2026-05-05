(** Server_dashboard_http_cache — cached_surface type and cache lifecycle. *)

type cached_surface = {
  mutable json : Yojson.Safe.t;
  mutable last_success_at : string option;
  mutable last_success_unix : float option;
  mutable last_attempt_at : string option;
  mutable last_attempt_unix : float option;
  mutable last_error : string option;
  mutable last_error_at : string option;
  mutable last_error_unix : float option;
}

let create_cached_surface json =
  {
    json;
    last_success_at = None;
    last_success_unix = None;
    last_attempt_at = None;
    last_attempt_unix = None;
    last_error = None;
    last_error_at = None;
    last_error_unix = None;
  }

let now_cache_stamp () =
  let ts = Unix.gettimeofday () in
  (ts, Masc_domain.now_iso ())

let json_of_string_option = function
  | Some value -> `String value
  | None -> `Null

let mark_cached_surface_attempt surface =
  let ts, iso = now_cache_stamp () in
  surface.last_attempt_unix <- Some ts;
  surface.last_attempt_at <- Some iso

let mark_cached_surface_success surface json =
  let ts, iso = now_cache_stamp () in
  surface.json <- json;
  surface.last_success_unix <- Some ts;
  surface.last_success_at <- Some iso;
  surface.last_error <- None;
  surface.last_error_at <- None;
  surface.last_error_unix <- None

let mark_cached_surface_error surface exn =
  let ts, iso = now_cache_stamp () in
  surface.last_error <- Some (Printexc.to_string exn);
  surface.last_error_at <- Some iso;
  surface.last_error_unix <- Some ts

let invalidate_cached_surface surface =
  surface.last_success_at <- None;
  surface.last_success_unix <- None;
  surface.last_attempt_at <- None;
  surface.last_attempt_unix <- None;
  surface.last_error <- None;
  surface.last_error_at <- None;
  surface.last_error_unix <- None

let upsert_assoc_field key value fields =
  (key, value) :: List.remove_assoc key fields

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
          (fun acc (key, value) -> upsert_assoc_field key value acc)
          existing extra_fields
      in
      `Assoc
        (upsert_assoc_field "projection_diagnostics" (`Assoc merged)
           (List.remove_assoc "projection_diagnostics" fields))
  | other -> other

let cached_surface_json surface =
  let now_ts = Unix.gettimeofday () in
  let cache_state, stale_reason, stale_age_ms =
    match surface.last_success_unix, surface.last_error_unix with
    | None, _ -> ("initializing", surface.last_error, None)
    | Some success_ts, Some error_ts when error_ts > success_ts ->
        ( "stale",
          surface.last_error,
          Some (int_of_float ((now_ts -. success_ts) *. 1000.0)) )
    | Some _, _ -> ("fresh", None, None)
  in
  extend_projection_diagnostics surface.json
    [
      ("cache_state", `String cache_state);
      ("last_success_at", json_of_string_option surface.last_success_at);
      ("last_attempt_at", json_of_string_option surface.last_attempt_at);
      ("last_error_at", json_of_string_option surface.last_error_at);
      ("stale_reason", json_of_string_option stale_reason);
      ( "stale_age_ms",
        match stale_age_ms with
        | Some value -> `Int value
        | None -> `Null );
    ]

let cached_surface_has_success surface =
  Option.is_some surface.last_success_unix

let cached_surface_or_first_success_json surface ~cache_key ~ttl ~clock
    ~timeout_sec compute =
  if cached_surface_has_success surface then
    cached_surface_json surface
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
    let json =
      Dashboard_cache.get_or_compute_with_timeout cache_key ~ttl ~clock
        ~timeout_sec compute_and_track
    in
    if cached_surface_has_success surface then cached_surface_json surface
    else json

let attach_projection_diagnostics json diagnostics =
  match json with
  | `Assoc fields -> `Assoc (("projection_diagnostics", diagnostics) :: fields)
  | other -> other

let projection_diagnostics_json ~surface ~started_at ~extra json =
  let build_ms = int_of_float ((Unix.gettimeofday () -. started_at) *. 1000.0) in
  let payload_bytes = String.length (Yojson.Safe.to_string json) in
  `Assoc
    ([
       ("surface", `String surface);
       ("build_ms", `Int build_ms);
       ("payload_bytes", `Int payload_bytes);
       ("generated_at", `String (Masc_domain.now_iso ()));
     ]
    @ extra)

let with_projection_diagnostics ~surface ~started_at ~extra json =
  attach_projection_diagnostics json
    (projection_diagnostics_json ~surface ~started_at ~extra json)

let initialized_json_opt ?(allow_initializing = false) = function
  | `Assoc fields as json -> (
      match List.assoc_opt "status" fields with
      | Some (`String "initializing") when not allow_initializing -> None
      | _ -> Some json)
  | _ -> None
