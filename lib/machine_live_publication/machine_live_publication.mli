(** Lock-free publication state shared by machine lanes. A reader may answer
    unchanged only from [Stable]; [Running] waits for the machine lock. *)
type 'mark t = No_screen | Stable of 'mark | Running of 'mark

val map : ('a -> 'b) -> 'a t -> 'b t
