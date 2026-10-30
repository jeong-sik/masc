(** Reserved exceptions that observer-isolation wrappers must not absorb.
    See {!reraise_if_reserved} in the interface for the contract. *)

let reraise_if_reserved exn =
  match exn with
  | Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _ ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | _ -> ()
;;
