val state : Keeper_librarian_durable_request.t -> (bool, string) result
(** Reconcile and check both actual original range receipts. True means all
    named ranges, false none; partial or range-less sources refuse. This read
    may recover Memory publication and supplies no source/ACK authority. *)
