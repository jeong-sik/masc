(** Server_bootstrap_pg — PG/database initialization functions.

    Extracted from Server_runtime_bootstrap to isolate database
    schema bootstrap steps into a focused module. *)

let init_task_backend () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Task_dispatch.init_pg pool with
      | Ok () ->
          Log.Task.info "PostgreSQL backend initialized"
      | Error e ->
          Log.Task.error "PG init failed: %s, using JSONL"
            (Types.show_masc_error e))
  | None -> Task_dispatch.init_jsonl ()

let inject_shared_pg_pool () =
  match Board_dispatch.get_pg_pool () with
  | Some _ ->
      Log.Server.info "PG shared pool available"
  | None ->
      Log.Server.info "No PG pool available"

let init_memory_pg_schema () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Memory_pg.ensure_schema pool with
      | Ok () -> ()
      | Error msg ->
          Log.MemoryPg.error "Schema init failed: %s (long_term_backend will use no-op)" msg)
  | None ->
      Log.MemoryPg.info "No PG pool available; long_term_backend will use JSONL fallback"

(** Run PG schema/bootstrap steps in a fixed order.
    These steps share the same PG pool and some of them mutate startup state,
    so deterministic sequencing is preferred over parallel fan-out. *)
let init_pg_schemas_sequential () =
  let errors = ref [] in
  let run_step label f =
    try f ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        errors := Printf.sprintf "%s: %s" label (Printexc.to_string exn) :: !errors
  in
  run_step "task_backend" init_task_backend;
  run_step "shared_pg_pool" inject_shared_pg_pool;
  run_step "memory_pg_schema" init_memory_pg_schema;
  match List.rev !errors with
  | [] -> ()
  | errs ->
      Log.Server.warn "PG schema init completed with errors: %s"
        (String.concat "; " errs)
