(** Server_dashboard_http_cache — cached_surface type and cache lifecycle. *)

type surface_snapshot = {
  json : Yojson.Safe.t;
  last_success_at : string option;
  last_success_unix : float option;
  last_attempt_at : string option;
  last_attempt_unix : float option;
  last_error : string option;
  last_error_at : string option;
  last_error_unix : float option;
}

type cached_surface = { mutable current : surface_snapshot }

let snapshot surface = surface.current

let create_cached_surface json =
  {
    current =
      {
        json;
        last_success_at = None;
        last_success_unix = None;
        last_attempt_at = None;
        last_attempt_unix = None;
        last_error = None;
        last_error_at = None;
        last_error_unix = None;
      };
  }

let now_cache_stamp () =
  let ts = Unix.gettimeofday () in
  (ts, Masc_domain.now_iso ())


(* Each mutator swaps a whole snapshot in one write. The previous form wrote
   the fields one at a time and was only free of torn reads because nothing
   between the writes could yield; a log call or a move onto a worker domain
   would have broken that silently. *)
let mark_cached_surface_attempt surface =
  let ts, iso = now_cache_stamp () in
  surface.current <-
    { surface.current with last_attempt_unix = Some ts; last_attempt_at = Some iso }

let mark_cached_surface_success surface json =
  let ts, iso = now_cache_stamp () in
  surface.current <-
    { surface.current with
      json
    ; last_success_unix = Some ts
    ; last_success_at = Some iso
    ; last_error = None
    ; last_error_at = None
    ; last_error_unix = None
    }

let mark_cached_surface_error_message surface message =
  let ts, iso = now_cache_stamp () in
  surface.current <-
    { surface.current with
      last_error = Some message
    ; last_error_at = Some iso
    ; last_error_unix = Some ts
    }

let mark_cached_surface_error surface exn =
  mark_cached_surface_error_message surface (Printexc.to_string exn)
;;

let invalidate_cached_surface surface =
  surface.current <-
    { surface.current with
      last_success_at = None
    ; last_success_unix = None
    ; last_attempt_at = None
    ; last_attempt_unix = None
    ; last_error = None
    ; last_error_at = None
    ; last_error_unix = None
    }

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
        (* Merge [extra_fields] into [existing] in a single traversal. The
           prior fold ran one [upsert_assoc_field] per extra field, and
           [upsert_assoc_field] is [(k,v) :: List.remove_assoc k ...] — so it
           scanned the whole diagnostic list and allocated a fresh list prefix
           once per extra field. Here we filter [existing] once, dropping any
           key present in [extra_fields], then prepend the extras in reverse.
           The resulting ordering matches the prior fold exactly:
           [(k_n,v_n); ...; (k_1,v_1); existing-minus-extras], preserving the
           relative order of unchanged entries. *)
        let extra_keys = List.map fst extra_fields in
        let kept =
          List.filter (fun (k, _) -> not (List.mem k extra_keys)) existing
        in
        List.rev_append (List.rev extra_fields) kept
      in
      `Assoc
        (upsert_assoc_field "projection_diagnostics" (`Assoc merged)
           (List.remove_assoc "projection_diagnostics" fields))
  | other -> other

let cached_surface_json cache =
  (* One read of the cell, so every field below comes from the same view. *)
  let surface = snapshot cache in
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
      ("last_success_at", Json_util.string_opt_to_json surface.last_success_at);
      ("last_attempt_at", Json_util.string_opt_to_json surface.last_attempt_at);
      ("last_error_at", Json_util.string_opt_to_json surface.last_error_at);
      ("stale_reason", Json_util.string_opt_to_json stale_reason);
      ( "stale_age_ms", Json_util.int_opt_to_json stale_age_ms );
    ]

let cached_surface_has_success cache =
  Option.is_some (snapshot cache).last_success_unix

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
