type t = {
  version_index : (string, string list) Hashtbl.t;
  override_tbl :
    (string, Prompt_override_persistence.entry) Hashtbl.t;
  meta_tbl :
    (string, Prompt_registry_types.prompt_meta) Hashtbl.t;
  prompts_dir : string option ref;
  markdown_dir : string option ref;
  mutex : Eio.Mutex.t;
  override_mutation_mutex : Eio.Mutex.t;
}

let create () =
  {
    version_index = Hashtbl.create 64;
    override_tbl = Hashtbl.create 16;
    meta_tbl = Hashtbl.create 32;
    prompts_dir = ref None;
    markdown_dir = ref None;
    mutex = Eio.Mutex.create ();
    override_mutation_mutex = Eio.Mutex.create ();
  }

let default_state : t = create ()

let default () = default_state

let with_lock state f =
  Eio_guard.with_mutex state.mutex f

let with_override_mutation_lock state f =
  (* This mutex coordinates transactions; it does not own their mutable state.
     Release it normally even when the callback raises. Keep the state mutex's
     separate poison policy and the guard's cancellation protection intact. *)
  let outcome =
    Eio_guard.with_mutex state.override_mutation_mutex (fun () ->
        match f () with
        | value -> Ok value
        | exception exn -> Error (exn, Printexc.get_raw_backtrace ()))
  in
  match outcome with
  | Ok value -> value
  | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
