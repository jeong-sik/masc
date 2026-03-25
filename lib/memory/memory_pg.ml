(** Memory_pg - PostgreSQL backend for OAS Memory.long_term_backend.

    Provides persistent key-value storage scoped by agent_name.
    Uses Caqti_eio with the same pool as Board_pg and Task_pg.

    Table: oas_memory_store (agent_name, key, value_json)
    UPSERT on (agent_name, key) unique constraint.

    @since 2.130.0 *)

let (let*) = Result.bind

type pool = (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t

(** {1 Schema DDL} *)

open Pg_infix

let create_table_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE TABLE IF NOT EXISTS oas_memory_store (\
     id SERIAL PRIMARY KEY, \
     agent_name TEXT NOT NULL, \
     key TEXT NOT NULL, \
     value_json TEXT NOT NULL, \
     created_at DOUBLE PRECISION NOT NULL DEFAULT extract(epoch from now()), \
     updated_at DOUBLE PRECISION NOT NULL DEFAULT extract(epoch from now()), \
     UNIQUE(agent_name, key) \
   )"

let create_idx_agent_key_q =
  (Caqti_type.unit ->. Caqti_type.unit)
  "CREATE INDEX IF NOT EXISTS idx_oas_memory_agent_key \
   ON oas_memory_store(agent_name, key)"

(** {1 Queries} *)

let upsert_q =
  (Caqti_type.(t3 string string string) ->. Caqti_type.unit)
  "INSERT INTO oas_memory_store (agent_name, key, value_json, created_at, updated_at) \
   VALUES ($1, $2, $3, extract(epoch from now()), extract(epoch from now())) \
   ON CONFLICT (agent_name, key) DO UPDATE \
   SET value_json = EXCLUDED.value_json, \
       updated_at = extract(epoch from now())"

let retrieve_q =
  (Caqti_type.(t2 string string) ->? Caqti_type.string)
  "SELECT value_json FROM oas_memory_store \
   WHERE agent_name = $1 AND key = $2"

let remove_q =
  (Caqti_type.(t2 string string) ->. Caqti_type.unit)
  "DELETE FROM oas_memory_store \
   WHERE agent_name = $1 AND key = $2"

let query_prefix_q =
  (Caqti_type.(t3 string string int) ->* Caqti_type.(t2 string string))
  "SELECT key, value_json FROM oas_memory_store \
   WHERE agent_name = $1 AND key LIKE $2 \
   ORDER BY updated_at DESC LIMIT $3"

(** {1 Schema Initialization} *)

let ensure_schema (pool : pool) : (unit, string) result =
  match Caqti_eio.Pool.use (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* () = C.exec create_table_q () in
    let* () = C.exec create_idx_agent_key_q () in
    Ok ()
  ) pool with
  | Ok () ->
    Log.MemoryPg.info "Schema initialized.";
    Ok ()
  | Error err ->
    let msg = Caqti_error.show err in
    Log.MemoryPg.error "Schema init failed: %s" msg;
    Error msg

(** {1 Backend Constructor} *)

(** Create an OAS [long_term_backend] backed by PostgreSQL.

    - [persist]: UPSERT (INSERT ... ON CONFLICT DO UPDATE)
    - [retrieve]: SELECT value_json, parse as JSON
    - [remove]: DELETE
    - [batch_persist]: iterate persist calls
    - [query]: SELECT ... WHERE key LIKE prefix% ORDER BY updated_at DESC *)
let make_backend ~(pool : pool) ~(agent_name : string)
  : Agent_sdk.Memory.long_term_backend =
  let persist ~key json =
    let value_str = Yojson.Safe.to_string json in
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.exec upsert_q (agent_name, key, value_str)
    ) pool with
    | Ok () -> Ok ()
    | Error err ->
      let msg = Caqti_error.show err in
      Log.MemoryPg.error "persist(%s/%s) failed: %s" agent_name key msg;
      Error msg
  in
  let retrieve ~key =
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.find_opt retrieve_q (agent_name, key)
    ) pool with
    | Ok (Some json_str) ->
      (try Some (Yojson.Safe.from_string json_str)
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         Log.MemoryPg.warn "retrieve(%s/%s) JSON parse failed: %s"
           agent_name key (Printexc.to_string exn);
         None)
    | Ok None -> None
    | Error err ->
      Log.MemoryPg.error "retrieve(%s/%s) failed: %s"
        agent_name key (Caqti_error.show err);
      None
  in
  let remove ~key =
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.exec remove_q (agent_name, key)
    ) pool with
    | Ok () -> Ok ()
    | Error err ->
      let msg = Caqti_error.show err in
      Log.MemoryPg.error "remove(%s/%s) failed: %s" agent_name key msg;
      Error msg
  in
  let batch_persist pairs =
    let errors = ref [] in
    List.iter (fun (key, json) ->
      match persist ~key json with
      | Ok () -> ()
      | Error msg -> errors := msg :: !errors
    ) pairs;
    match !errors with
    | [] -> Ok ()
    | errs ->
      let first_err = match errs with e :: _ -> e | [] -> "unknown" in
      let msg = Printf.sprintf "batch_persist: %d/%d failed: %s"
        (List.length errs) (List.length pairs)
        first_err in
      Error msg
  in
  let query ~prefix ~limit =
    let like_pattern = prefix ^ "%" in
    match Caqti_eio.Pool.use (fun conn ->
      let module C = (val conn : Caqti_eio.CONNECTION) in
      C.collect_list query_prefix_q (agent_name, like_pattern, limit)
    ) pool with
    | Ok rows ->
      List.filter_map (fun (key, json_str) ->
        try Some (key, Yojson.Safe.from_string json_str)
        with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
          Log.MemoryPg.warn "query(%s/%s) JSON parse failed: %s"
            agent_name key (Printexc.to_string exn);
          None
      ) rows
    | Error err ->
      Log.MemoryPg.error "query(%s/%s%%) failed: %s"
        agent_name prefix (Caqti_error.show err);
      []
  in
  { Agent_sdk.Memory.persist; retrieve; remove; batch_persist; query }
