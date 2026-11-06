type entry = { mutable count : int }

type t =
  { state : (string, entry) Hashtbl.t
  ; mutex : Mutex.t
  }

type occurrence_outcome =
  | First
  | Repeated of int

let component_separator = "\x00"
let create ?(initial_capacity = 32) () =
  { state = Hashtbl.create initial_capacity; mutex = Mutex.create () }
;;

let key components = String.concat component_separator components

let with_lock t f = Mutex.protect t.mutex f

let make_entry () = { count = 1 }

let record t ~key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.state key with
    | None ->
      Hashtbl.replace t.state key (make_entry ());
      First
    | Some entry ->
      entry.count <- entry.count + 1;
      Repeated entry.count)
;;

let reset t = with_lock t (fun () -> Hashtbl.reset t.state)
let cardinality t = with_lock t (fun () -> Hashtbl.length t.state)
