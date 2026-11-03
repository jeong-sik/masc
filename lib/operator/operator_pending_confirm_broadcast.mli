(** The name of the push the terminal client still reads for the
    confirmations waiting for an operator. The server announces those
    changes as [operator_pending_confirm_invalidated]; this name goes with
    the terminal reader that still decodes it. *)

val changed_event : string
