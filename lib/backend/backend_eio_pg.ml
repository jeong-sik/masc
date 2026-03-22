(** Backend_eio_pg - Eio-native PostgreSQL backend implementation.

    Extracted from Backend_eio.Postgres for separation of concerns.
    Uses Caqti-eio for non-blocking PostgreSQL access with zstd compression.

    Types come from Backend_eio_types (shared with Backend_eio).
    Backend_eio.Postgres delegates to this module.
*)

module Compression = Backend_eio_compression

(** {1 Types} *)

include Backend_eio_types

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
open Caqti_request.Infix

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

let set_if_not_exists_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "INSERT INTO masc_kv (key, value, updated_at) VALUES ($1, $2, NOW()) ON CONFLICT DO NOTHING"

let acquire_lock_q =
  (Caqti_type.(t3 string string int) ->. Caqti_type.unit)
  "INSERT INTO masc_kv (key, value, expires_at, updated_at) \
   VALUES ($1, $2, NOW() + $3 * INTERVAL '1 second', NOW()) \
   ON CONFLICT DO NOTHING"

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

(* Schema creation *)
let create_schema_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS masc_kv (\
     key TEXT PRIMARY KEY, \
     value TEXT NOT NULL, \
     expires_at TIMESTAMP, \
     created_at TIMESTAMP DEFAULT NOW(), \
     updated_at TIMESTAMP DEFAULT NOW() \
   )"

let create_index_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_masc_kv_expires ON masc_kv(expires_at)"

let (let*) = Result.bind

let caqti_error_to_masc err =
  IOError (Caqti_error.show err)

let create ~sw ~env ~url ~cluster_name ~node_id =
  let uri = Uri.of_string url in
  let max_pool = match Sys.getenv_opt "MASC_PG_POOL_SIZE" with
    | Some s -> (try int_of_string s with _ -> 10)
    | None -> 10
  in
  let pool_config = Caqti_pool_config.create
      ~max_size:max_pool ~max_idle_size:(min max_pool 3)
      ~max_idle_age:(Some (Mtime.Span.of_uint64_ns 30_000_000_000L))
      ~max_use_count:(Some 50) () in
  let uri =
    if Uri.get_query_param uri "keepalives" <> None then uri
    else uri
      |> (fun u -> Uri.add_query_param' u ("keepalives", "1"))
      |> (fun u -> Uri.add_query_param' u ("keepalives_idle", "15"))
      |> (fun u -> Uri.add_query_param' u ("keepalives_interval", "5"))
      |> (fun u -> Uri.add_query_param' u ("keepalives_count", "3"))
  in
  match Caqti_eio_unix.connect_pool ~sw ~stdenv:env ~pool_config uri with
  | Error err -> Error (caqti_error_to_masc err)
  | Ok pool ->
      (* Initialize schema *)
      let init_result = Caqti_eio.Pool.use (fun conn ->
        let module C = (val conn : Caqti_eio.CONNECTION) in
        let* () = C.exec create_schema_q () in
        let* () = C.exec create_index_q () in
        Ok ()
      ) pool in
      (match init_result with
       | Error err -> Error (caqti_error_to_masc err)
       | Ok () -> Ok { pool; namespace = cluster_name; node_id })

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
  | _ -> false

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

let acquire_lock t ~key ~owner ~ttl_seconds =
  let lock_key = namespaced_key t.namespace ("locks:" ^ key) in
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* existing = C.find_opt get_q lock_key in
    match existing with
    | Some _ -> Ok false
    | None ->
        let* () = C.exec acquire_lock_q (lock_key, owner, ttl_seconds) in
        Ok true
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

let health_check t =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    C.find health_check_q ()
  ) t.pool with
  | Ok 1 -> Ok { latency_ms = 0.0; is_healthy = true }
  | _ -> Ok { latency_ms = 0.0; is_healthy = false }
