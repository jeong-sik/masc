type source = Candidate | Partition
type change = {canonical_masc_root : string; keeper_name : string; source : source}
type listener = {notify : change -> unit}

let listeners : listener list Atomic.t = Atomic.make []
let listener_failures = Atomic.make 0

let subscribe notify =
  let listener = {notify} in
  Lockfree_atomic.update listeners (fun current -> listener :: current);
  fun () -> Lockfree_atomic.update listeners (List.filter (fun current -> current != listener))

let notify change = List.iter (fun listener ->
  try listener.notify change with
  (* cancel-guard-ok: after-attempt metadata cannot replace the original
     producer result, uncertain failure or cancellation. *)
  | _ -> ignore (Atomic.fetch_and_add listener_failures 1)) (Atomic.get listeners)

let with_attempt ~base_path ~keeper_name ~source f =
  let canonical_masc_root = Fs_compat.realpath_lenient (Common.masc_dir_from_base_path ~base_path) in
  let change = {canonical_masc_root; keeper_name; source} in
  let attempted = Atomic.make false in
  (* fun-protect-finally-ok: ownership was resolved before the operation;
     notify only visits synchronous, non-I/O metadata callbacks. *)
  Fun.protect ~finally:(fun () -> if Atomic.get attempted then notify change)
    (fun () -> f (fun () -> Atomic.set attempted true))
