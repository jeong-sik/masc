type t = {
  registry :
    (string, Prompt_registry_types.prompt_entry) Hashtbl.t;
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
    registry = Hashtbl.create 64;
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
  Eio_guard.with_mutex state.override_mutation_mutex f
