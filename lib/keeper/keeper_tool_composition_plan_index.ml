(* Rows only, oldest declaration first. A keeper carries a handful of
   compositions per turn, so a linear list under a mutex is the whole cost —
   the same sizing argument as the approval registry's waiter list. *)
type t =
  { mutable rows : (string * string list) list
  ; mutable descriptors : Keeper_tool_descriptor.t list option
  ; mutex : Stdlib.Mutex.t
  }

let create () = { rows = []; descriptors = None; mutex = Stdlib.Mutex.create () }

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

let bind_descriptors t descriptors =
  Stdlib.Mutex.protect t.mutex (fun () ->
    match t.descriptors with
    | None -> t.descriptors <- Some descriptors
    | Some existing when List.length existing = List.length descriptors
        && List.for_all2 ( == ) existing descriptors -> ()
    | Some _ -> invalid_arg "approval turn already owns a different descriptor surface")

let descriptors t = Stdlib.Mutex.protect t.mutex (fun () -> t.descriptors)
