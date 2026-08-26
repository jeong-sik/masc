(** See keeper_identity_tool_index.mli. *)

type t = {
  mutex : Mutex.t;
  mutable rows : (string * bool option) list;
}

let create () = { mutex = Mutex.create (); rows = [] }

let shared_instance = create ()
let shared () = shared_instance

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f
;;

let record t ~tool_name ~read_only =
  with_lock t (fun () ->
    t.rows <- (tool_name, read_only) :: List.remove_assoc tool_name t.rows)
;;

let read_only t ~tool_name = with_lock t (fun () -> List.assoc_opt tool_name t.rows)
let forget_all t = with_lock t (fun () -> t.rows <- [])
