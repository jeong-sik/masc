(** Cascade trust JSONL snapshot — see [cascade_trust_persist.mli].

    Layering note: this module sits at the cascade layer (alongside
    [cascade_health_tracker]) and does NOT depend on dashboard layer
    serializers, even though the JSON shape mirrors
    [Dashboard_cascade.provider_entry_to_json].  The duplication is
    intentional — dashboard depends on cascade, not the reverse. *)

module H = Cascade_health_tracker

let snapshot_interval_s =
  match Sys.getenv_opt "MASC_CASCADE_TRUST_SNAPSHOT_SEC" with
  | None -> 60.0
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 60.0
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some v when v > 0.0 -> v
      | _ ->
        Log.Misc.warn
          "Invalid MASC_CASCADE_TRUST_SNAPSHOT_SEC=%S, using 60.0" raw;
        60.0

(* ── Store cache ────────────────────────────────────── *)

let store_ref : (string * Dated_jsonl.t) option ref = ref None

let reset_for_testing () = store_ref := None

let get_or_create_store ~base_path : Dated_jsonl.t =
  match !store_ref with
  | Some (cached, s) when String.equal cached base_path -> s
  | _ ->
    let dir = Filename.concat base_path "cascade_trust" in
    Fs_compat.mkdir_p dir;
    let s = Dated_jsonl.create ~base_dir:dir () in
    store_ref := Some (base_path, s);
    s

(* ── Serialization ──────────────────────────────────── *)

let provider_info_to_json (info : H.provider_info) : Yojson.Safe.t =
  let opt_float = function
    | Some v when Float.is_finite v -> `Float v
    | _ -> `Null
  in
  let fingerprints =
    `List
      (List.map
         (fun (fp, count) ->
           `Assoc
             [ ("fingerprint", `String fp); ("count", `Int count) ])
         info.top_fingerprints)
  in
  let last_failure_at =
    match info.last_failure_at with
    | Some t -> `Float t
    | None -> `Null
  in
  let cooldown_expires_at =
    match info.cooldown_expires_at with
    | Some t -> `Float t
    | None -> `Null
  in
  `Assoc
    [ ("provider_key", `String info.provider_key)
    ; ("success_rate", `Float info.success_rate)
    ; ("consecutive_failures", `Int info.consecutive_failures)
    ; ("in_cooldown", `Bool info.in_cooldown)
    ; ("cooldown_expires_at", cooldown_expires_at)
    ; ("events_in_window", `Int info.events_in_window)
    ; ("rejected_in_window", `Int info.rejected_in_window)
    ; ("p50_latency_ms", opt_float info.p50_latency_ms)
    ; ("p95_latency_ms", opt_float info.p95_latency_ms)
    ; ("latency_samples", `Int info.latency_samples)
    ; ("avg_confidence", opt_float info.avg_confidence)
    ; ("confidence_samples", `Int info.confidence_samples)
    ; ("avg_cost_usd", opt_float info.avg_cost_usd)
    ; ("cost_samples", `Int info.cost_samples)
    ; ("health_score", `Float info.health_score)
    ; ("top_fingerprints", fingerprints)
    ; ("last_failure_at", last_failure_at)
    ]

let snapshot_to_json ~ts (infos : H.provider_info list) : Yojson.Safe.t =
  `Assoc
    [ ("ts", `Float ts)
    ; ("providers", `List (List.map provider_info_to_json infos))
    ]

let float_opt = function
  | `Float v when Float.is_finite v -> Some v
  | `Int v -> Some (float_of_int v)
  | `Intlit raw ->
    (match Safe_ops.float_of_string_safe raw with
     | Some v when Float.is_finite v -> Some v
     | _ -> None)
  | _ -> None

let int_opt = function
  | `Int v -> Some v
  | `Intlit raw -> Safe_ops.int_of_string_safe raw
  | _ -> None

let restore_provider_of_json json =
  let open Yojson.Safe.Util in
  match json |> member "provider_key" with
  | `String provider_key when String.trim provider_key <> "" ->
    let restore_consecutive_failures =
      json |> member "consecutive_failures" |> int_opt |> Option.value ~default:0
    in
    let restore_cooldown_until = json |> member "cooldown_expires_at" |> float_opt in
    let restore_last_failure_at = json |> member "last_failure_at" |> float_opt in
    let restore_top_fingerprints =
      match json |> member "top_fingerprints" with
      | `List rows ->
        List.filter_map
          (fun row ->
            match row |> member "fingerprint", row |> member "count" |> int_opt with
            | `String fp, Some count when String.trim fp <> "" && count > 0 ->
              Some (fp, count)
            | _ -> None)
          rows
      | _ -> []
    in
    Some
      H.
        { restore_provider_key = provider_key
        ; restore_consecutive_failures
        ; restore_cooldown_until
        ; restore_last_failure_at
        ; restore_top_fingerprints
        ; restore_latency_ms = json |> member "p50_latency_ms" |> float_opt
        ; restore_confidence = json |> member "avg_confidence" |> float_opt
        ; restore_cost_usd = json |> member "avg_cost_usd" |> float_opt
        }
  | _ -> None

(* ── Public API ─────────────────────────────────────── *)

let snapshot_now ~base_path =
  try
    let store = get_or_create_store ~base_path in
    let infos = H.all_providers H.global in
    let json = snapshot_to_json ~ts:(Unix.gettimeofday ()) infos in
    Dated_jsonl.append store json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn "cascade_trust_persist: snapshot_now failed: %s"
      (Printexc.to_string exn)

let hydrate_latest ~base_path =
  try
    let store = get_or_create_store ~base_path in
    match Dated_jsonl.read_recent store 1 with
    | [] -> 0
    | latest :: _ ->
      (match Yojson.Safe.Util.member "providers" latest with
       | `List providers ->
         let restored =
           List.filter_map restore_provider_of_json providers
           |> H.restore_providers H.global
         in
         if restored > 0 then
           Log.Misc.info
             "cascade_trust_persist: hydrated %d provider health row(s)"
             restored;
         restored
       | _ -> 0)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Misc.warn "cascade_trust_persist: hydrate_latest failed: %s"
      (Printexc.to_string exn);
    0

let start_snapshot_fiber ~sw ~clock ~base_path =
  let _hydrated = hydrate_latest ~base_path in
  let _store = get_or_create_store ~base_path in
  Eio.Fiber.fork ~sw (fun () ->
    Log.Misc.info
      "cascade_trust_persist: snapshot fiber started (interval=%.0fs)"
      snapshot_interval_s;
    let rec loop () =
      Eio.Time.sleep clock snapshot_interval_s;
      snapshot_now ~base_path;
      loop ()
    in
    loop ());
  Shutdown.register
    ~name:"cascade_trust_persist_snapshot"
    ~priority:25
    (fun () ->
      try snapshot_now ~base_path
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        Log.Misc.warn
          "cascade_trust_persist: shutdown snapshot failed: %s"
          (Printexc.to_string exn))
