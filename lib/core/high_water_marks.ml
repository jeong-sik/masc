module Names = Map.Make (String)

type t = int Names.t Atomic.t

let create () = Atomic.make Names.empty

(* A writer that loses the compare-and-set reads the newer map and decides
   again, so a higher number recorded meanwhile is never replaced. *)
let rec raise_to t name n =
  let held = Atomic.get t in
  match Names.find_opt name held with
  | Some h when h >= n -> ()
  | Some _ | None ->
    if not (Atomic.compare_and_set t held (Names.add name n held)) then raise_to t name n
;;

let find t name = Names.find_opt name (Atomic.get t)
