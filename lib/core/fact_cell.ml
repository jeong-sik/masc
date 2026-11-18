type 'a slot =
  | Unfilled
  | Filled of 'a

(* A state is never put back: each change makes a record with the next
   generation, so two states of one cell are never the same block and a
   compare-and-set cannot take an old state for the current one. *)
type 'a seen =
  { generation : int
  ; slot : 'a slot
  }

type 'a t = 'a seen Atomic.t

let slot seen = seen.slot
let generation seen = seen.generation
let make () = Atomic.make { generation = 0; slot = Unfilled }
let see = Atomic.get

let held cell =
  match (Atomic.get cell).slot with
  | Filled value -> Some value
  | Unfilled -> None
;;

let moved cell seen slot =
  Atomic.compare_and_set cell seen { generation = seen.generation + 1; slot }
;;

let rec forget cell =
  let seen = Atomic.get cell in
  if not (moved cell seen Unfilled) then forget cell
;;

let settle cell seen ~step =
  let next =
    match seen.slot with
    | Unfilled -> Some Unfilled
    | Filled value -> Option.map (fun value -> Filled value) (step value)
  in
  match next with
  | Some slot when moved cell seen slot -> ()
  | Some _ | None -> forget cell
;;

type ('a, 'e) filled =
  | Held of 'a
  | Read_and_kept of 'a
  | Read_not_kept of 'a
  | Read_failed of 'e

let fill cell ~read =
  let seen = Atomic.get cell in
  match seen.slot with
  | Filled value -> Held value
  | Unfilled ->
    (match read () with
     | Error error -> Read_failed error
     | Ok value ->
       if moved cell seen (Filled value) then Read_and_kept value else Read_not_kept value)
;;
