(* See keeper_wfq_overflow.mli for documentation. *)

type entry = {
  keeper_id : string;
  weight : int;
  enqueued_at : float;
}

type slot = {
  entry : entry;
  mutable deficit : int;
}

type t = {
  mutable slots : slot list;
  (* Insertion order preserved.  Deficit-weighted selection is
     reconstructed at [wake_one] time instead of maintaining a
     priority heap; for fleet sizes ≤ 50 this O(N) walk is faster
     than heap maintenance overhead per enqueue. *)
  mutex : Stdlib.Mutex.t;
}

let create () = { slots = []; mutex = Stdlib.Mutex.create () }

let with_lock t f =
  Stdlib.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.mutex) f

let contains t keeper_id =
  List.exists (fun s -> String.equal s.entry.keeper_id keeper_id) t.slots

let enqueue t entry =
  with_lock t (fun () ->
    if not (contains t entry.keeper_id) then
      t.slots <- t.slots @ [ { entry; deficit = 0 } ])

(* Pick the slot with maximum deficit/weight ratio.  Tie-break by
   earlier enqueued_at (FIFO).  Returns (chosen_slot, others). *)
let pick_max_deficit slots =
  let score s = float_of_int s.deficit /. float_of_int s.entry.weight in
  let rec loop best best_score acc = function
    | [] -> (best, acc)
    | s :: rest ->
        let s_score = score s in
        if s_score > best_score
           || (s_score = best_score
               && s.entry.enqueued_at < best.entry.enqueued_at)
        then loop s s_score (best :: acc) rest
        else loop best best_score (s :: acc) rest
  in
  match slots with
  | [] -> None
  | first :: rest ->
      let chosen, others = loop first (score first) [] rest in
      Some (chosen, others)

let wake_one t =
  with_lock t (fun () ->
    match pick_max_deficit t.slots with
    | None -> None
    | Some (chosen, others) ->
        (* Increment deficit of all unchosen slots by their weight.
           DRR step: skipped flows accrue deficit so they win the next
           round. *)
        List.iter (fun s -> s.deficit <- s.deficit + s.entry.weight) others;
        t.slots <-
          List.filter
            (fun s -> not (String.equal s.entry.keeper_id chosen.entry.keeper_id))
            t.slots;
        Some chosen.entry)

let remove t keeper_id =
  with_lock t (fun () ->
    let before = List.length t.slots in
    t.slots <-
      List.filter
        (fun s -> not (String.equal s.entry.keeper_id keeper_id))
        t.slots;
    before <> List.length t.slots)

let snapshot t =
  with_lock t (fun () -> List.map (fun s -> s.entry) t.slots)

let depth t = with_lock t (fun () -> List.length t.slots)

let deficit_of t keeper_id =
  with_lock t (fun () ->
    match
      List.find_opt
        (fun s -> String.equal s.entry.keeper_id keeper_id)
        t.slots
    with
    | Some s -> Some s.deficit
    | None -> None)
