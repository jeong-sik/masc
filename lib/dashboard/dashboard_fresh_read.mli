(** Share a queued read only until its worker starts. A later caller may start
    another calculation, and no completed result is cached. *)
type 'a t

val create : unit -> 'a t

val run : 'a t -> key:string -> 'a Pool_work.t -> 'a
(** Each key is an authority boundary chosen by the caller. The server switch
    owns a shared producer while each caller keeps its own cancellation scope.
    When its last waiter leaves, the producer cancels and joins its worker. If
    there is no server switch, callers submit separate reads. *)
