type mode =
  | Auto
  | Yolo

let mode_to_string = function
  | Auto -> "auto"
  | Yolo -> "yolo"

let mode_of_string = function
  | "auto" -> Some Auto
  | "yolo" -> Some Yolo
  | _ -> None

(* Overrides only, oldest set first. An operator watches a handful of
   keepers, so a linear list under a mutex is the whole cost — the same
   sizing argument as the approval registry's waiter list. *)
type t =
  { mutable overrides : (string * mode) list
  ; mutex : Stdlib.Mutex.t
  }

let create () = { overrides = []; mutex = Stdlib.Mutex.create () }

(* Created at load, so a stance set over HTTP and a gate consulting it cannot
   see two different registries. *)
let shared_registry = create ()
let shared () = shared_registry

let resolve t ~keeper_name =
  Stdlib.Mutex.protect t.mutex (fun () ->
      match List.assoc_opt keeper_name t.overrides with
      | Some mode -> mode
      | None -> Auto)

let set t ~keeper_name mode =
  Stdlib.Mutex.protect t.mutex (fun () ->
      let without =
        List.filter (fun (name, _) -> not (String.equal name keeper_name)) t.overrides
      in
      t.overrides <-
        (match mode with
         | Auto -> without
         | Yolo -> without @ [ (keeper_name, mode) ]))

let overrides t = Stdlib.Mutex.protect t.mutex (fun () -> t.overrides)
