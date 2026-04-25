(** MASC Cache - Shared Context Store (Eio Native)

    Pure synchronous cache operations.
    Compatible with Eio direct-style concurrency.

    에이전트 간 컨텍스트 공유 및 캐싱:
    - 파일 콘텐츠 해시
    - API 응답 (JIRA, GitHub)
    - 임베딩 결과
    - 코드베이스 요약

    Storage: .masc/cache/
*)

(** Eviction sample threshold: if >50% of sampled entries are expired,
    run a full eviction pass. *)
let eviction_sample_threshold = 0.5

(** Cache entry *)
type cache_entry = {
  key: string;
  value: string;
  created_at: float;
  expires_at: float option;  (* None = no expiry *)
  tags: string list;
}

(** Get cache directory *)
let cache_dir (config : Coord_utils.config) =
  Filename.concat (Coord_utils.masc_dir config) "cache"

(** Ensure cache directory exists *)
let ensure_cache_dir config =
  let dir = cache_dir config in
  Fs_compat.mkdir_p dir

(* Pattern is a static character class — hoist out of [sanitize_key]
   so we build the DFA once per process instead of per cache lookup. *)
let unsafe_filename_char_re = Re.Pcre.re "[^a-zA-Z0-9_-]" |> Re.compile

(** Sanitize key for filename *)
let sanitize_key key =
  (* Replace unsafe chars with underscore, limit length *)
  let safe = Re.replace_string unsafe_filename_char_re ~by:"_" key in
  if String.length safe > 64 then
    String.sub safe 0 64
  else safe

(** Keep a readable filename prefix while reserving room for a collision-proof hash suffix. *)
let key_filename_prefix key =
  let safe = sanitize_key key in
  if String.length safe > 48 then
    String.sub safe 0 48
  else safe

(** 16 hex chars gives a compact, stable disambiguator without making cache filenames unwieldy. *)
let key_filename_hash key =
  Digestif.SHA256.(digest_string key |> to_hex)
  |> fun hex -> String.sub hex 0 16

let cache_filename key =
  let prefix = key_filename_prefix key in
  let suffix = key_filename_hash key in
  if prefix = "" then suffix else prefix ^ "-" ^ suffix

(** Get cache file path *)
let cache_file config key =
  Filename.concat (cache_dir config) (cache_filename key ^ ".json")

let legacy_cache_file config key =
  Filename.concat (cache_dir config) (sanitize_key key ^ ".json")

let entry_to_json (entry : cache_entry) : Yojson.Safe.t =
  `Assoc [
    ("key", `String entry.key);
    ("value", `String entry.value);
    ("value_size", `Int (String.length entry.value));
    ("created_at", `Float entry.created_at);
    ("expires_at", match entry.expires_at with
      | Some t -> `Float t
      | None -> `Null);
    ("tags", `List (List.map (fun t -> `String t) entry.tags));
  ]

(** Entry from JSON *)
let entry_of_json (json : Yojson.Safe.t) : cache_entry option =
  let module U = Yojson.Safe.Util in
  try
    let key = json |> U.member "key" |> U.to_string in
    let value = json |> U.member "value" |> U.to_string in
    let created_at = json |> U.member "created_at" |> U.to_float in
    let expires_at = match json |> U.member "expires_at" with
      | `Null -> None
      | `Float f -> Some f
      | _ -> None
    in
    let tags = json |> U.member "tags" |> U.to_list |> List.map U.to_string in
    Some { key; value; created_at; expires_at; tags }
  with
  | U.Type_error (msg, _) ->
    Log.Misc.error "JSON type error in entry_of_json: %s" msg;
    None
  | e ->
    Log.Misc.error "Unexpected error in entry_of_json: %s" (Printexc.to_string e);
    None

let read_entry_file path =
  match Safe_ops.read_json_file_logged ~label:"cache_entry" path with
  | None -> None
  | Some json -> entry_of_json json

let read_matching_entry path ~key =
  match read_entry_file path with
  | Some entry when String.equal entry.key key -> Some entry
  | _ -> None

let remove_file_if_exists path =
  if Sys.file_exists path then (
    try
      Sys.remove path;
      true
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> false)
  else false

(** Check if entry is expired *)
let is_expired entry =
  match entry.expires_at with
  | None -> false
  | Some exp -> Time_compat.now () > exp

(** Timestamp of last batch eviction, used to throttle periodic checks.
    Atomic to prevent eviction stampede under concurrent fiber access. *)
let last_batch_eviction = Atomic.make 0.0

(** Minimum interval between batch evictions (seconds). *)
let batch_eviction_interval = 60.0

(** Cached entry count to avoid Sys.readdir on every set() call.
    -1 = uninitialized; lazily populated on first count_entries call.
    Updated incrementally on set/delete/evict/clear to prevent
    file descriptor exhaustion from repeated concurrent directory scans.
    See: system_log seq 8719 "Too many open files" on .masc/cache. *)
let cached_entry_count = Atomic.make (-1)

(** Reset cached entry count. Call when switching cache directories (tests). *)
let reset_cached_entry_count () = Atomic.set cached_entry_count (-1)

let decrement_cached_entry_count () =
  let rec loop () =
    let current = Atomic.get cached_entry_count in
    if current < 0 then
      ()
    else
      let next = max 0 (current - 1) in
      if not (Atomic.compare_and_set cached_entry_count current next) then
        loop ()
  in
  loop ()

let maybe_migrate_legacy_entry config ~key entry =
  let legacy_path = legacy_cache_file config key in
  let primary_path = cache_file config key in
  if primary_path = legacy_path || not (Sys.file_exists legacy_path) || Sys.file_exists primary_path then
    ()
  else
    try
      let json = entry_to_json entry in
      let content = Yojson.Safe.pretty_to_string json in
      Fs_compat.save_file primary_path content;
      if not (remove_file_if_exists legacy_path) then
        Atomic.set cached_entry_count (-1)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        Log.Misc.warn "cache_eio maybe_migrate_legacy_entry failed: %s"
          (Printexc.to_string exn)

(** Guard to prevent concurrent directory scan stampedes.
    Only one fiber may scan the cache directory at a time;
    concurrent callers return [fallback] immediately. *)
let scan_in_progress = Atomic.make false

let with_scan_guard ~fallback f =
  if Atomic.compare_and_set scan_in_progress false true then
    Fun.protect ~finally:(fun () -> Atomic.set scan_in_progress false) f
  else fallback

(** Read .json filenames from cache directory. Single readdir call. *)
let read_cache_filenames dir =
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")

(** Evict all expired cache entries. Returns count of evicted entries.
    Guarded: only one scan runs at a time; concurrent calls return 0. *)
let evict_expired config =
  let dir = cache_dir config in
  with_scan_guard ~fallback:0 (fun () ->
    let filenames = read_cache_filenames dir in
    let evicted = List.fold_left (fun count filename ->
      let path = Filename.concat dir filename in
      match read_entry_file path with
      | Some entry when is_expired entry ->
          Safe_ops.remove_file_logged ~context:"cache_evict" path;
          count + 1
      | _ -> count
    ) 0 filenames in
    (* Refresh cached count after eviction *)
    let remaining = List.length filenames - evicted in
    Atomic.set cached_entry_count remaining;
    evicted)

(** Check expired ratio and evict if > 50% are expired.
    Throttled to run at most once per [batch_eviction_interval] seconds.
    Returns number of evicted entries (0 if skipped). *)
let maybe_evict_expired config =
  let now = Time_compat.now () in
  let old_val = Atomic.get last_batch_eviction in
  if now -. old_val < batch_eviction_interval then 0
  else if not (Atomic.compare_and_set last_batch_eviction old_val now) then
    (* Another fiber already claimed this eviction window *)
    0
  else begin
    let dir = cache_dir config in
    if not (Sys.file_exists dir) then 0
    else
      let files = read_cache_filenames dir in
      let total = List.length files in
      if total = 0 then 0
      else begin
        (* Sample up to 10 entries to estimate expired ratio *)
        let sample_size = min 10 total in
        let sample = List.filteri (fun i _ -> i < sample_size) files in
        let expired_count = List.fold_left (fun acc filename ->
          let path = Filename.concat dir filename in
          match read_entry_file path with
          | Some entry when is_expired entry -> acc + 1
          | _ -> acc
        ) 0 sample in
        let ratio = float_of_int expired_count /. float_of_int sample_size in
        if ratio > eviction_sample_threshold then
          evict_expired config
        else
          0
      end
  end

(** Count current number of cache entries.
    Uses cached count when available; falls back to directory scan on first call. *)
let count_entries config =
  let c = Atomic.get cached_entry_count in
  if c >= 0 then c
  else
    let dir = cache_dir config in
    let count =
      if not (Sys.file_exists dir) then 0
      else List.length (read_cache_filenames dir)
    in
    Atomic.set cached_entry_count count;
    count

(** Set cache entry - synchronous *)
let set config ~key ~value ?(ttl_seconds : int option) ?(tags : string list = []) ()
    : (cache_entry, string) result =
  (* BUG-016: Reject empty key *)
  if String.length (String.trim key) = 0 then
    Error "Cache key must not be empty"
  else
  (* BUG-013: Per-entry size limit *)
  let max_size = Env_config.Cache.max_entry_size in
  if String.length value > max_size then
    Error (Printf.sprintf "Value exceeds max entry size (%d > %d bytes)" (String.length value) max_size)
  else begin
    ensure_cache_dir config;
    let primary_path = cache_file config key in
    let legacy_path = legacy_cache_file config key in
    let primary_entry = read_entry_file primary_path in
    let legacy_entry =
      if String.equal primary_path legacy_path then None
      else read_entry_file legacy_path
    in
    let is_overwrite =
      Option.fold ~none:false ~some:(fun entry -> String.equal entry.key key) primary_entry
      || Option.fold ~none:false ~some:(fun entry -> String.equal entry.key key) legacy_entry
    in
    let cap_check =
      match primary_entry with
      | Some entry when not (String.equal entry.key key) ->
          Error "Cache file collision detected for hashed key"
      | _ ->
          (* BUG-012: Max entries cap -- evict expired first, then reject if still full.
             Overwrites and legacy-path migrations bypass the cap check. *)
          let max_entries = Env_config.Cache.max_entries in
          let current = count_entries config in
          if (not is_overwrite) && current >= max_entries then begin
            let _evicted = evict_expired config in
            let after_evict = count_entries config in
            if after_evict >= max_entries then
              Error (Printf.sprintf "Cache full (%d entries, max %d)" after_evict max_entries)
            else Ok ()
          end else Ok ()
    in
    Result.bind cap_check (fun () ->
        let now = Time_compat.now () in
        let expires_at = Option.map (fun ttl -> now +. float_of_int ttl) ttl_seconds in
        let entry = { key; value; created_at = now; expires_at; tags } in
        let json = entry_to_json entry in
        let content = Yojson.Safe.pretty_to_string json in
        try
          let target_exists = Sys.file_exists primary_path in
          Fs_compat.save_file primary_path content;
          let removed_legacy =
            if not (String.equal primary_path legacy_path) then
              (match legacy_entry with
               | Some existing when String.equal existing.key key ->
                   remove_file_if_exists legacy_path
               | _ -> false)
            else false
          in
          if removed_legacy then
            Atomic.set cached_entry_count (-1)
          else if not target_exists then
            ignore (Atomic.fetch_and_add cached_entry_count 1);
          Ok entry
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | e -> Error (Printexc.to_string e))
  end

(** Get cache entry - synchronous.
    Also triggers batch eviction when expired ratio > 50% (throttled). *)
let get config ~key : (cache_entry option, string) result =
  let primary_path = cache_file config key in
  let legacy_path = legacy_cache_file config key in
  let located =
    match read_matching_entry primary_path ~key with
    | Some entry -> Some (primary_path, entry, false)
    | None ->
        if String.equal primary_path legacy_path then None
        else
          match read_matching_entry legacy_path ~key with
          | Some entry -> Some (legacy_path, entry, true)
          | None -> None
  in
  match located with
  | None ->
    (* Trigger batch eviction check even on miss *)
    let _evicted = maybe_evict_expired config in
    Ok None
  | Some (path, entry, from_legacy) ->
      try
        if is_expired entry then begin
          (* Auto-delete expired entries *)
          if remove_file_if_exists path then decrement_cached_entry_count ();
          let _evicted = maybe_evict_expired config in
          Ok None
        end else begin
          if from_legacy then maybe_migrate_legacy_entry config ~key entry;
          let _evicted = maybe_evict_expired config in
          Ok (Some entry)
        end
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Printexc.to_string e)

(** Delete cache entry - synchronous *)
let delete config ~key : (bool, string) result =
  let primary_path = cache_file config key in
  let legacy_path = legacy_cache_file config key in
  try
    let deleted_primary = remove_file_if_exists primary_path in
    let deleted_legacy =
      if String.equal primary_path legacy_path then false
      else
        match read_matching_entry legacy_path ~key with
        | Some _ -> remove_file_if_exists legacy_path
        | None -> false
    in
    if deleted_primary then decrement_cached_entry_count ();
    if deleted_legacy then decrement_cached_entry_count ();
    Ok (deleted_primary || deleted_legacy)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printexc.to_string e)

(** List all cache entries - synchronous.
    Guarded: concurrent calls return empty list to prevent FD stampede. *)
let list config ?(tag : string option) () : cache_entry list =
  let dir = cache_dir config in
  if not (Sys.file_exists dir) then
    []
  else
    with_scan_guard ~fallback:[] (fun () ->
      let entries = read_cache_filenames dir in
      let deduped = Hashtbl.create (List.length entries) in
      List.iter (fun filename ->
        let path = Filename.concat dir filename in
        match read_entry_file path with
        | Some entry ->
            if is_expired entry then begin
              if remove_file_if_exists path then decrement_cached_entry_count ()
            end else begin
              let include_entry =
                match tag with
                | None -> true
                | Some t -> List.mem t entry.tags
              in
              if include_entry then
                let is_primary =
                  String.equal filename (cache_filename entry.key ^ ".json")
                in
                match Hashtbl.find_opt deduped entry.key with
                | Some (existing, existing_is_primary)
                  when existing.created_at > entry.created_at
                    || (existing.created_at = entry.created_at
                        && (existing_is_primary || not is_primary)) -> ()
                | _ -> Hashtbl.replace deduped entry.key (entry, is_primary)
            end
        | None -> ()
      ) entries;
      Hashtbl.fold (fun _ (entry, _) acc -> entry :: acc) deduped [])

(** Clear all cache entries - synchronous *)
let clear config : (int, string) result =
  let dir = cache_dir config in
  if not (Sys.file_exists dir) then
    Ok 0
  else
    try
      let entries = read_cache_filenames dir in
      let count = List.fold_left (fun acc filename ->
        let path = Filename.concat dir filename in
        Safe_ops.remove_file_logged ~context:"cache_clear" path;
        acc + 1
      ) 0 entries in
      Atomic.set cached_entry_count 0;
      Ok count
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> Error (Printexc.to_string e)

(** Get cache statistics - synchronous.
    Guarded: concurrent calls return zeros to prevent FD stampede. *)
let stats config : (int * int * float, string) result =
  (* Returns: (total_entries, expired_entries, total_size_bytes) *)
  let dir = cache_dir config in
  if not (Sys.file_exists dir) then
    Ok (0, 0, 0.0)
  else
    with_scan_guard ~fallback:(Ok (0, 0, 0.0)) (fun () ->
      try
        let entries = read_cache_filenames dir in
        let total, expired, size = List.fold_left (fun (t, e, s) filename ->
          let path = Filename.concat dir filename in
          let file_size = (Unix.stat path).st_size in
          let is_exp =
            match read_entry_file path with
            | Some entry -> is_expired entry
            | None -> false
          in
          (t + 1, e + (if is_exp then 1 else 0), s +. float_of_int file_size)
        ) (0, 0, 0.0) entries in
        Ok (total, expired, size)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e -> Error (Printexc.to_string e))

(** Format stats for display *)
let format_stats (total, expired, size) =
  Printf.sprintf "Cache: %d entries (%d expired), %.1f KB"
    total expired (size /. 1024.0)
