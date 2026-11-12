(* See the [.mli]. A [Hashtbl] under [Stdlib.Mutex], as in
   [Runtime_quota_window]: notes come from Keeper fibers on several domains
   and reads come from the HTTP projection. *)

let refusals : (Runtime_quota_window.scope, float) Hashtbl.t = Hashtbl.create 4
let mu = Stdlib.Mutex.create ()

let note_refused ~scope ~at =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.replace refusals scope at)

let note_answered ~scope =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.remove refusals scope)

let refused_at ~scope =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.find_opt refusals scope)
