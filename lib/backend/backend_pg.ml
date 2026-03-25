(** Backend_pg - Eio-native PostgreSQL backend implementation.

    Extracted from Backend.Postgres for separation of concerns.
    Uses Caqti-eio for non-blocking PostgreSQL access with zstd compression.

    Types come from Backend_types (shared with Backend).
    Backend.Postgres delegates to this module.
*)

module Compression = Backend_compression

(** {1 Types} *)

include Backend_types

(** {1 PostgreSQL Backend} *)

type t = {
  pool: (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t;
  namespace: string;
  node_id: string;
}

let namespaced_key namespace key =
  if namespace = "" || namespace = "default" then key
  else namespace ^ ":" ^ key

let strip_namespace namespace key =
  let prefix = namespace ^ ":" in
  let prefix_len = String.length prefix in
  if String.length key >= prefix_len && String.sub key 0 prefix_len = prefix then
    String.sub key prefix_len (String.length key - prefix_len)
  else key

(* Caqti 2.x query definitions *)
open Pg_infix

let get_q =
  (Caqti_type.string ->? Caqti_type.string)
  "SELECT value FROM masc_kv WHERE key = $1 AND (expires_at IS NULL OR expires_at > NOW())"

let set_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "INSERT INTO masc_kv (key, value, updated_at) VALUES ($1, $2, NOW()) \
   ON CONFLICT (key) DO UPDATE SET value = $2, updated_at = NOW()"

let delete_q =
  (Caqti_type.string ->. Caqti_type.unit)
  "DELETE FROM masc_kv WHERE key = $1"

let exists_q =
  (Caqti_type.string ->? Caqti_type.int)
  "SELECT 1 FROM masc_kv WHERE key = $1 AND (expires_at IS NULL OR expires_at > NOW())"

let list_keys_q =
  (Caqti_type.string ->* Caqti_type.string)
  "SELECT key FROM masc_kv WHERE key LIKE $1 AND (expires_at IS NULL OR expires_at > NOW())"

let get_all_q =
  (Caqti_type.string ->* Caqti_type.(t2 string string))
  "SELECT key, value FROM masc_kv WHERE key LIKE $1 AND (expires_at IS NULL OR expires_at > NOW()) ORDER BY key DESC LIMIT 200"

let get_all_matching_recent_q =
  (Caqti_type.(t4 string string float int) ->* Caqti_type.(t2 string string))
  "SELECT key, value \
   FROM masc_kv \
   WHERE key LIKE $1 \
     AND key LIKE $2 \
     AND updated_at >= TO_TIMESTAMP($3) \
     AND (expires_at IS NULL OR expires_at > NOW()) \
   ORDER BY updated_at DESC, key DESC \
   LIMIT $4"

let set_if_not_exists_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "INSERT INTO masc_kv (key, value, updated_at) VALUES ($1, $2, NOW()) ON CONFLICT DO NOTHING"

let compare_and_swap_q =
  (Caqti_type.(t3 string string string) ->? Caqti_type.int)
  "UPDATE masc_kv SET value = $3, updated_at = NOW() \
   WHERE key = $1 AND value = $2 \
   RETURNING 1"

let acquire_lock_q =
  (Caqti_type.(t3 string string int) ->? Caqti_type.int)
  "INSERT INTO masc_kv (key, value, expires_at, updated_at) \
   VALUES ($1, $2, NOW() + $3 * INTERVAL '1 second', NOW()) \
   ON CONFLICT (key) DO UPDATE SET \
     value = EXCLUDED.value, \
     expires_at = EXCLUDED.expires_at, \
     updated_at = NOW() \
   WHERE masc_kv.expires_at IS NOT NULL AND masc_kv.expires_at <= NOW() \
   RETURNING 1"

let release_lock_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "DELETE FROM masc_kv WHERE key = $1 AND value = $2"

let extend_lock_q =
  (Caqti_type.(t3 string int string) ->. Caqti_type.unit)
  "UPDATE masc_kv SET expires_at = NOW() + $2 * INTERVAL '1 second', updated_at = NOW() \
   WHERE key = $1 AND value = $3"

let health_check_q =
  (Caqti_type.unit ->! Caqti_type.int)
  "SELECT 1"

(* Pub/Sub queries (using table as queue for message passing)

   PostgreSQL LISTEN/NOTIFY Integration:
   - publish: INSERT + pg_notify for real-time push
   - subscribe: Table polling for reliability (messages persist)

   Hybrid approach benefits:
   - NOTIFY: Instant notification to LISTEN clients (< 1ms)
   - Table queue: Reliability (no message loss if client disconnected)
   - Caqti limitation: LISTEN requires dedicated connection outside pool
*)
let publish_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "INSERT INTO masc_pubsub (channel, message) VALUES ($1, $2)"

(* pg_notify sends real-time notification to all LISTEN clients
   Payload limited to 8000 bytes by PostgreSQL.
   NOTE: pg_notify() returns void but SELECT always produces one row.
   Using ->! unit (expect one row, discard void value) avoids Caqti error. *)
let notify_q =
  (Caqti_type.(t2 string string) ->! Caqti_type.unit)
  "SELECT pg_notify($1, $2)"

(* PostgreSQL pg_notify payload limit (actual limit is 8000, use 7900 for safety margin) *)
let pg_notify_max_payload = 7900

let subscribe_q =
  (Caqti_type.string ->? Caqti_type.string)
  "DELETE FROM masc_pubsub WHERE id = (\
     SELECT id FROM masc_pubsub \
     WHERE channel = $1 \
     ORDER BY id \
     LIMIT 1 \
     FOR UPDATE SKIP LOCKED\
   ) RETURNING message"

(* Schema creation queries *)
let create_schema_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_kv (\
     key TEXT PRIMARY KEY, \
     value TEXT NOT NULL, \
     expires_at TIMESTAMP, \
     created_at TIMESTAMP DEFAULT NOW(), \
     updated_at TIMESTAMP DEFAULT NOW() \
   )"

let create_pubsub_table_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_pubsub (\
     id SERIAL PRIMARY KEY, \
     channel TEXT NOT NULL, \
     message TEXT NOT NULL, \
     created_at TIMESTAMP DEFAULT NOW() \
   )"

let create_index_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_masc_kv_expires ON masc_kv(expires_at)"

let create_pubsub_index_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_masc_pubsub_channel ON masc_pubsub(channel, id)"

let create_pubsub_created_at_index_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_masc_pubsub_created_at ON masc_pubsub(created_at)"

(* Cleanup old pubsub messages - returns count of deleted rows *)
let cleanup_pubsub_q =
  (Caqti_type.int ->! Caqti_type.int)
  "WITH deleted AS (DELETE FROM masc_pubsub WHERE created_at < NOW() - $1 * INTERVAL '1 day' RETURNING 1) SELECT COUNT(*)::int FROM deleted"

(* Cleanup keeping max N messages per channel *)
let cleanup_pubsub_limit_q =
  (Caqti_type.int ->! Caqti_type.int)
  "WITH ranked AS (\
     SELECT id, ROW_NUMBER() OVER (PARTITION BY channel ORDER BY id DESC) as rn \
     FROM masc_pubsub\
   ), deleted AS (\
     DELETE FROM masc_pubsub WHERE id IN (SELECT id FROM ranked WHERE rn > $1) RETURNING 1\
   ) SELECT COUNT(*)::int FROM deleted"

let (let*) = Result.bind

(** Read MASC_PG_POOL_SIZE from env, clamped to [1, 50]. Default: 10. *)
let configured_pool_size () =
  match Sys.getenv_opt "MASC_PG_POOL_SIZE" with
  | Some s -> (try max 1 (min (int_of_string s) 50) with Failure _ -> 10)
  | None -> 10

(** Add TCP keepalive query params to a URI if not already present. *)
let uri_with_keepalive uri =
  if Uri.get_query_param uri "keepalives" <> None then uri
  else uri
    |> (fun u -> Uri.add_query_param' u ("keepalives", "1"))
    |> (fun u -> Uri.add_query_param' u ("keepalives_idle", "15"))
    |> (fun u -> Uri.add_query_param' u ("keepalives_interval", "5"))
    |> (fun u -> Uri.add_query_param' u ("keepalives_count", "3"))

(* Rate-limited error logging to avoid flooding stderr
   when the PG pool is exhausted (e.g. Supabase MaxClientsInSessionMode). *)
let _pg_last_error_log = Atomic.make 0.0

let caqti_error_to_masc err =
  let msg = Caqti_error.show err in
  let now = Unix.gettimeofday () in
  let last = Atomic.get _pg_last_error_log in
  if now -. last > 60.0 then begin
    Atomic.set _pg_last_error_log now;
    Log.Backend.error "[EioPG] %s" msg
  end;
  IOError msg

let create ~sw ~env ~url ~cluster_name ~node_id =
  let uri = Uri.of_string url in
  let max_pool = configured_pool_size () in
  let pool_config = Caqti_pool_config.create
      ~max_size:max_pool ~max_idle_size:(min max_pool 3)
      ~max_idle_age:(Some (Mtime.Span.of_uint64_ns 30_000_000_000L))
      ~max_use_count:(Some 50) () in
  let uri = uri_with_keepalive uri in
  Log.Backend.info "[EioPG] connecting pool (max_size=%d, max_idle_size=%d, keepalives=on)..."
    max_pool (min max_pool 3);
  match Caqti_eio_unix.connect_pool ~sw ~stdenv:env ~pool_config uri with
  | Error err ->
      Log.Backend.error "[EioPG] pool creation failed: %s" (Caqti_error.show err);
      Error (caqti_error_to_masc err)
  | Ok pool ->
      Log.Backend.info "[EioPG] pool created, initializing schema...";
      (* Parallel DDL init: 2-phase to respect table→index dependency.
         Each fiber gets its own connection from pool; all DDL uses IF NOT EXISTS. *)
      let exec_ddl q =
        match Caqti_eio.Pool.use (fun conn ->
          let module C = (val conn : Caqti_eio.CONNECTION) in
          C.exec q ()
        ) pool with
        | Ok () -> ()
        | Error e -> raise (Failure (Caqti_error.show e))
      in
      let init_result =
        try
          (* Phase 1: create tables in parallel (independent) *)
          let (_: unit * unit) = Eio.Fiber.pair
            (fun () -> exec_ddl create_schema_q)
            (fun () -> exec_ddl create_pubsub_table_q)
          in
          (* Phase 2: create indexes in parallel (tables now exist) *)
          Eio.Fiber.all [
            (fun () -> exec_ddl create_index_q);
            (fun () -> exec_ddl create_pubsub_index_q);
            (fun () -> exec_ddl create_pubsub_created_at_index_q);
          ];
          Ok ()
        with Failure msg -> Error (IOError msg)
      in
      (match init_result with
       | Error err ->
           Log.Backend.error "[EioPG] schema init failed: %s" (show_error err);
           Error err
       | Ok () ->
           Log.Backend.info "[EioPG] connected and schema ready";
           at_exit (fun () ->
             try Caqti_eio.Pool.drain pool
             with exn ->
               Log.Backend.warn "[EioPG] pool drain failed: %s"
                 (Printexc.to_string exn));
           Ok { pool; namespace = cluster_name; node_id })

let create_readonly ~sw ~env ~url ~cluster_name ~node_id =
  let uri = Uri.of_string url in
  (* Readonly pools need >1 connection to avoid "Invalid concurrent
     usage" when multiple Eio fibers within the same executor domain
     call Pool.use concurrently. Use half the main pool size, minimum 3. *)
  let max_pool = max 3 (configured_pool_size () / 2) in
  let pool_config = Caqti_pool_config.create ~max_size:max_pool () in
  let uri = uri_with_keepalive uri in
  match Caqti_eio_unix.connect_pool ~sw ~stdenv:env ~pool_config uri with
  | Error err -> Error (caqti_error_to_masc err)
  | Ok pool ->
      Ok { pool; namespace = cluster_name; node_id }

let close _t = ()

let get_pool t = t.pool

let get t key =
  let nkey = namespaced_key t.namespace key in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find_opt get_q nkey
  ) t.pool with
  | Ok (Some v) -> Ok (Compression.decompress_auto v)
  | Ok None -> Error (NotFound key)
  | Error err -> Error (caqti_error_to_masc err)

let set t key value =
  let nkey = namespaced_key t.namespace key in
  let compressed = Compression.compress_with_header value in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec set_q (nkey, compressed)
  ) t.pool with
  | Ok () -> Ok ()
  | Error err -> Error (caqti_error_to_masc err)

let exists t key =
  let nkey = namespaced_key t.namespace key in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find_opt exists_q nkey
  ) t.pool with
  | Ok (Some _) -> true
  | Ok None -> false
  | Error err ->
    let now = Unix.gettimeofday () in
    if now -. Atomic.get _pg_last_error_log > 60.0 then begin
      Atomic.set _pg_last_error_log now;
      Log.Backend.error "[EioPG:exists] %s" (Caqti_error.show err)
    end;
    false

let delete t key =
  let nkey = namespaced_key t.namespace key in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec delete_q nkey
  ) t.pool with
  | Ok () -> Ok ()
  | Error err -> Error (caqti_error_to_masc err)

let list_keys t ~prefix =
  let nprefix = namespaced_key t.namespace prefix in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list list_keys_q (nprefix ^ "%")
  ) t.pool with
  | Ok keys -> Ok (List.map (strip_namespace t.namespace) keys)
  | Error err -> Error (caqti_error_to_masc err)

let get_all t ~prefix =
  let nprefix = namespaced_key t.namespace prefix in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.collect_list get_all_q (nprefix ^ "%")
  ) t.pool with
  | Ok pairs ->
      Ok (List.map (fun (k, v) ->
        (strip_namespace t.namespace k, Compression.decompress_auto v)
      ) pairs)
  | Error err -> Error (caqti_error_to_masc err)

let get_all_matching_recent t ~prefix ~suffix ~updated_since ~limit =
  if limit <= 0 then
    Ok []
  else
    let nprefix = namespaced_key t.namespace prefix in
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.collect_list get_all_matching_recent_q
        (nprefix ^ "%", "%" ^ suffix, updated_since, limit)
    ) t.pool with
    | Ok pairs ->
        Ok (List.map (fun (k, v) ->
          (strip_namespace t.namespace k, Compression.decompress_auto v)
        ) pairs)
    | Error err -> Error (caqti_error_to_masc err)

let set_if_not_exists t key value =
  let nkey = namespaced_key t.namespace key in
  let compressed = Compression.compress_with_header value in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* existing = C.find_opt exists_q nkey in
    match existing with
    | Some _ -> Ok false
    | None ->
        let* () = C.exec set_if_not_exists_q (nkey, compressed) in
        Ok true
  ) t.pool with
  | Ok b -> Ok b
  | Error err -> Error (caqti_error_to_masc err)

let compare_and_swap t ~key ~expected ~value =
  let nkey = namespaced_key t.namespace key in
  let compressed_new = Compression.compress_with_header value in
  (* CAS compares stored payload bytes directly. This preserves the public
     raw-value contract because Backend_compression is deterministic for the
     current simplified zstd path (fixed level, no external dictionary). *)
  let compressed_expected = Compression.compress_with_header expected in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* row = C.find_opt compare_and_swap_q (nkey, compressed_expected, compressed_new) in
    Ok (Option.is_some row)
  ) t.pool with
  | Ok b -> Ok b
  | Error err -> Error (caqti_error_to_masc err)

let acquire_lock t ~key ~owner ~ttl_seconds =
  let lock_key = namespaced_key t.namespace ("locks:" ^ key) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* acquired = C.find_opt acquire_lock_q (lock_key, owner, ttl_seconds) in
    Ok (Option.is_some acquired)
  ) t.pool with
  | Ok b -> Ok b
  | Error err -> Error (caqti_error_to_masc err)

let release_lock t ~key ~owner =
  let lock_key = namespaced_key t.namespace ("locks:" ^ key) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec release_lock_q (lock_key, owner)
  ) t.pool with
  | Ok () -> Ok true
  | Error err -> Error (caqti_error_to_masc err)

let extend_lock t ~key ~owner ~ttl_seconds =
  let lock_key = namespaced_key t.namespace ("locks:" ^ key) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.exec extend_lock_q (lock_key, ttl_seconds, owner)
  ) t.pool with
  | Ok () -> Ok true
  | Error err -> Error (caqti_error_to_masc err)

(* Pub/Sub using table as queue + NOTIFY for real-time *)
let publish t ~channel ~message =
  let compressed = Compression.compress_with_header message in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    (* Insert into table for reliability (persistent queue) *)
    let* () = C.exec publish_q (channel, compressed) in
    (* Send NOTIFY for real-time push to LISTEN clients
       Skip NOTIFY for large payloads - subscribers poll anyway *)
    let total_payload = String.length channel + String.length message + 1 in
    if total_payload <= pg_notify_max_payload then
      C.find notify_q (channel, message)
    else begin
      Log.debug ~ctx:"Pubsub" "NOTIFY skipped: payload too large (%d bytes, limit %d)"
        total_payload pg_notify_max_payload;
      Ok ()
    end
  ) t.pool with
  | Ok () -> Ok 1
  | Error err -> Error (caqti_error_to_masc err)

let subscribe t ~channel ~callback =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find_opt subscribe_q channel
  ) t.pool with
  | Ok (Some msg) ->
      let decompressed = Compression.decompress_auto msg in
      callback decompressed;
      Ok ()
  | Ok None -> Ok ()
  | Error err -> Error (caqti_error_to_masc err)

let health_check t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find health_check_q ()
  ) t.pool with
  | Ok 1 -> Ok { latency_ms = 0.0; is_healthy = true }
  | _ -> Ok { latency_ms = 0.0; is_healthy = false }

(* Cleanup old pubsub messages by age (days) *)
let cleanup_pubsub_by_age t ~days =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find cleanup_pubsub_q days
  ) t.pool with
  | Ok count -> Ok count
  | Error err -> Error (caqti_error_to_masc err)

(* Cleanup pubsub messages keeping only max_messages per channel *)
let cleanup_pubsub_by_limit t ~max_messages =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find cleanup_pubsub_limit_q max_messages
  ) t.pool with
  | Ok count -> Ok count
  | Error err -> Error (caqti_error_to_masc err)

(* Combined cleanup: by age first, then by limit *)
let cleanup_pubsub t ~days ~max_messages =
  let age_result = cleanup_pubsub_by_age t ~days in
  let limit_result = cleanup_pubsub_by_limit t ~max_messages in
  match (age_result, limit_result) with
  | (Ok age_count, Ok limit_count) -> Ok (age_count + limit_count)
  | (Error e, _) -> Error e
  | (_, Error e) -> Error e
