(** Lock-free atomic update helpers.

    These are thin wrappers around [Stdlib.Atomic.compare_and_set] that retry
    until the read-modify-write succeeds. They are safe to call from multiple
    OCaml 5 domains or Eio fibers operating on the same [Atomic.t]. *)

let update r f =
  let rec loop () =
    let current = Atomic.get r in
    let next = f current in
    if not (Atomic.compare_and_set r current next) then loop ()
  in
  loop ()
;;
