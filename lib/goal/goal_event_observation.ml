type listener = { notify : base_path:string -> unit }
let listeners : listener list Atomic.t = Atomic.make []
let failures = Atomic.make 0
let rec update f =
  let old = Atomic.get listeners in
  if not (Atomic.compare_and_set listeners old (f old)) then update f
let subscribe notify =
  let listener = { notify } in
  update (fun old -> listener :: old);
  fun () -> update (List.filter (fun current -> current != listener))
let attempted ~base_path =
  List.iter (fun listener ->
    match listener.notify ~base_path with
    | () -> ()
    | exception _ ->
      (* cancel-guard-ok: preserve the ledger's result and cleanup. *)
      ignore (Atomic.fetch_and_add failures 1)) (Atomic.get listeners)
let failed_notifications () = Atomic.get failures
