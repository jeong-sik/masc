type owner = { masc_root : string; keeper_name : string }
type listener = { notify : owner -> unit }
let listeners : listener list Atomic.t = Atomic.make []
let failures = Atomic.make 0
let rec update f =
  let old = Atomic.get listeners in
  if not (Atomic.compare_and_set listeners old (f old)) then update f
let subscribe notify =
  let listener = { notify } in
  update (fun old -> listener :: old);
  fun () -> update (List.filter (fun current -> current != listener))
let attempted owner =
  List.iter (fun listener ->
    match listener.notify owner with
    | () -> ()
    | exception _ ->
      (* cancel-guard-ok: metadata cannot replace an already offered write's
         result; the caller observes its actual cancellation at its next check. *)
      ignore (Atomic.fetch_and_add failures 1)) (Atomic.get listeners)
let failed_notifications () = Atomic.get failures
