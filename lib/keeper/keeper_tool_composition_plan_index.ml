(* Rows only, oldest declaration first. A keeper carries a handful of
   compositions per turn, so a linear list under a mutex is the whole cost —
   the same sizing argument as the approval registry's waiter list. *)
type t =
  { mutable rows : (string * string list) list
  ; mutex : Stdlib.Mutex.t
  }

let create () = { rows = []; mutex = Stdlib.Mutex.create () }

(* Created at load, so a bundle built on one fiber and a policy consulted on
   another see the same instance. *)
let shared_index = create ()
let shared () = shared_index

let record t ~composition ~node_tools =
  Stdlib.Mutex.protect t.mutex (fun () ->
    let without =
      List.filter (fun (name, _) -> not (String.equal name composition)) t.rows
    in
    t.rows <- without @ [ composition, node_tools ])
;;

let node_tools t ~composition =
  Stdlib.Mutex.protect t.mutex (fun () -> List.assoc_opt composition t.rows)
;;

let forget_all t = Stdlib.Mutex.protect t.mutex (fun () -> t.rows <- [])
