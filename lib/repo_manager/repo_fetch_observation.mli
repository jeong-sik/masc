type t =
  { common_dir : string
  ; origin_url : string
  ; target_ref : string
  ; oid : string
  ; observed_at_unix : int
  }

val filename : string
(** Receipt written only after a successful managed fetch of the named ref. *)

val read : common_dir:string -> t option
(** Invalid, missing, or relocated receipts are unavailable. *)

val write : common_dir:string -> t -> (unit, string) result
(** Atomically replace the receipt in the repository's common Git directory. *)
