(** Server_bootstrap_pg — Backend initialization functions.

    Filesystem-first: PG schemas are only initialized when
    MASC_STORAGE_TYPE=postgres is explicitly configured.
    Memory_pg schema init removed (memory_oas_bridge uses JSONL). *)

let init_task_backend () =
  match Board_dispatch.get_pg_pool () with
  | Some pool -> (
      match Task_dispatch.init_pg pool with
      | Ok () ->
          Log.Task.info "PostgreSQL task backend initialized"
      | Error e ->
          Log.Task.error "PG task init failed: %s, using JSONL"
            (Types.show_masc_error e))
  | None -> Task_dispatch.init_jsonl ()

let inject_shared_pg_pool () =
  match Board_dispatch.get_pg_pool () with
  | Some _ ->
      Log.Server.info "PG shared pool available"
  | None ->
      Log.Server.info "No PG pool; filesystem-first mode"

(** Run backend bootstrap steps in a fixed order.
    Memory_pg schema init removed: long_term_backend always uses JSONL. *)
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
  match List.rev !errors with
  | [] -> ()
  | errs ->
      Log.Server.warn "Backend init completed with errors: %s"
        (String.concat "; " errs)
