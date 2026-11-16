(** Reserved exceptions that observer-isolation wrappers must not absorb.
    See {!reraise_if_reserved} in the interface for the contract. *)

let rec contains_reserved = function
  | Out_of_memory | Stack_overflow | Sys.Break | Eio.Cancel.Cancelled _ ->
    true
  | Fun.Finally_raised inner -> contains_reserved inner
  | Eio.Exn.Multiple errors ->
    List.exists (fun (error, _backtrace) -> contains_reserved error) errors
  | _ -> false
;;

let reraise_if_reserved exn =
  if contains_reserved exn
  then Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
;;
