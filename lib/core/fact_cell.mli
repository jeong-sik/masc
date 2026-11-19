(** One fact kept in memory beside the file that holds it
    (RFC "Keeper row facts are kept in memory by their writers", section 2).

    The file is the authority. A cell is either {!Unfilled}, which claims
    nothing, or {!Filled} with the value a read of the file gives while no
    one is changing the file.

    Three parties touch a cell, and each uses one function:

    - whoever changes the file in a way it can follow calls {!see} before the
      change and {!settle} after it;
    - whoever changes the file in any other way, or cannot tell whether it
      changed, calls {!forget} after it;
    - a reader calls {!fill}.

    None of them takes a lock for the cell. Every change of a cell is a
    compare-and-set to a state the cell has not held before, so a party that
    lost a race sees it and gives way: a fill is not kept, a settle forgets. *)

val keep_in_this_process : unit -> unit
(** Say that this process holds the workspace's writer lease. A cell follows
    the changes made by the process it lives in, and a row another process
    appends moves nothing here. So facts are kept only in the process that
    holds the lease, and there only for files that only the lease holder
    changes; whoever keeps a cell for a kind of file answers the second part.

    Said once: by the server, through
    [Server_startup_takeover.keep_store_facts], and by a test executable that
    stands for it. It is not taken back. *)

val kept_in_this_process : unit -> bool
(** Whether {!keep_in_this_process} was said. A reader in a process that has
    not said it (the TUI, a command line tool) reads the file every time and
    fills no cell. *)

type 'a slot =
  | Unfilled
  | Filled of 'a

type 'a seen
(** What a cell held at one moment. *)

val slot : 'a seen -> 'a slot

val generation : 'a seen -> int
(** How many times the cell had changed. *)

type 'a t

val make : unit -> 'a t
(** An unfilled cell. *)

val see : 'a t -> 'a seen

val held : 'a t -> 'a option
(** The value of a filled cell. *)

val forget : 'a t -> unit
(** Leave the cell unfilled, in a state it has not held before. A fill that
    saw the cell before this is not kept, even when the cell was unfilled
    already. *)

val settle : 'a t -> 'a seen -> step:('a -> 'a option) -> unit
(** [settle cell seen ~step] follows one change of the file. [seen] is the
    cell before the change, and [step] gives the value after the change from
    the value before it, or [None] when it cannot be told.

    A filled cell moves to [step]'s value and an unfilled one stays unfilled;
    both move to a new state, so a fill that read the file before the change
    is not kept. The cell is forgotten instead when [step] gives [None], and
    when the cell is no longer the one seen: the value there may or may not
    count the change. *)

(** How a reader got its value. *)
type ('a, 'e) filled =
  | Held of 'a  (** The cell was filled. Nothing was read. *)
  | Read_and_kept of 'a  (** Read, and the cell now holds it. *)
  | Read_not_kept of 'a
      (** Read, and the cell changed meanwhile. The value is the reader's
          own answer and the cell does not hold it. *)
  | Read_failed of 'e  (** The cell is as it was. *)

val fill : 'a t -> read:(unit -> ('a, 'e) result) -> ('a, 'e) filled
(** The cell's value, read with [read] when the cell is unfilled. The cell is
    seen before [read] runs and takes the value only if it is still the one
    seen. A caller that hands the read to a pool calls [fill] inside the job:
    a cell seen before the wait for a worker would lose to every write that
    lands during the wait. *)
