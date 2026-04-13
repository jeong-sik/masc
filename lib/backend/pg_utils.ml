(** Shared PostgreSQL utilities.

    Centralizes common types and helpers used across backend_pg, task_pg,
    board_pg_queries, and memory_pg. Extracted from duplicated definitions
    to ensure consistent pool sizing and keepalive behavior.

    - Pool type alias for [(Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t]
    - [configured_pool_size]: reads MASC_PG_POOL_SIZE, clamped to [1, 50], default 10.
    - [uri_with_keepalive]: adds TCP keepalive query params to a PostgreSQL URI. *)

(** Canonical pool type used across all PG modules. *)
type pool = (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t

(** Read MASC_PG_POOL_SIZE from env, clamped to [1, 50]. Default: 10.
    Previously duplicated in backend_pg.ml (default 10) and backend_types.ml
    (default 5 — bug). Unified to default 10 with consistent clamping. *)
let configured_pool_size () =
  match Sys.getenv_opt "MASC_PG_POOL_SIZE" with
  | Some s -> (try max 1 (min (int_of_string s) 50) with Failure _ -> 10)
  | None -> 10

(** Add TCP keepalive query params to a URI if not already present.
    Prevents idle connection drops on long-lived PG connections
    (e.g. Supabase session mode, AWS RDS with short tcp_keepalive_time). *)
let uri_with_keepalive uri =
  if Uri.get_query_param uri "keepalives" <> None then uri
  else uri
    |> (fun u -> Uri.add_query_param' u ("keepalives", "1"))
    |> (fun u -> Uri.add_query_param' u ("keepalives_idle", "15"))
    |> (fun u -> Uri.add_query_param' u ("keepalives_interval", "5"))
    |> (fun u -> Uri.add_query_param' u ("keepalives_count", "3"))
