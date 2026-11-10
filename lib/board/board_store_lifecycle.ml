(* Loaders return [(int, string * exn) result] so the caller is forced to
   acknowledge persistence-load failures.  Best-effort semantics live here
   at the call site, not hidden inside the loader bodies. *)
let log_persistence_result ~kind = function
  | Ok _ -> ()
  | Error (path, e) ->
    Log.BoardLog.error
      "load %s failed: path=%s reason=%s (continuing with best-effort partial state)"
      kind path (Printexc.to_string e)

let load_all_persisted store =
  let open Board_store_load in
  log_persistence_result ~kind:"posts" (load_persisted_posts store);
  log_persistence_result ~kind:"comments" (load_persisted_comments store);
  recalculate_reply_counts store;
  log_persistence_result ~kind:"votes" (load_persisted_votes store);
  log_persistence_result ~kind:"reactions" (load_persisted_reactions store);
  log_persistence_result ~kind:"sub-boards" (Board_core.reload_sub_boards store)

let new_global_lazy () =
  Eio.Lazy.from_fun ~cancel:`Protect (fun () ->
    let store = Board_core.create_store
      ~base_path:(Board_paths.board_base_path ()) () in
    load_all_persisted store;
    store)

(* The owner has one cell; constructing/resetting it does not resolve a root. *)
let global_lazy = ref (new_global_lazy ())
let global () = Eio.Lazy.force !global_lazy
let reset_global_for_test () = global_lazy := new_global_lazy ()
