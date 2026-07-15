(** Process-local serialization for high-level per-Keeper lifecycle commands. *)

module Lock_key = struct
  type t = string

  let equal = String.equal
  let hash = Hashtbl.hash
end

module Lock_table = Ephemeron.K1.Make (Lock_key)

type lock_entry =
  { key : string
  ; mutex : Cross_context_mutex.t
  }

let table_mu = Stdlib.Mutex.create ()
let locks : lock_entry Lock_table.t = Lock_table.create 0

let lock_for ~base_path ~keeper_name =
  let key =
    Keeper_registry_types.registry_key
      ~base_path
      (String.trim keeper_name)
  in
  Stdlib.Mutex.protect table_mu (fun () ->
    Lock_table.clean locks;
    match Lock_table.find_opt locks key with
    | Some entry -> entry
    | None ->
      let entry = { key; mutex = Cross_context_mutex.create () } in
      Lock_table.add locks key entry;
      entry)
;;

let with_lock ~base_path ~keeper_name f =
  let entry = lock_for ~base_path ~keeper_name in
  Cross_context_mutex.with_durable_lock entry.mutex (fun () ->
    ignore entry.key;
    f ())
;;
