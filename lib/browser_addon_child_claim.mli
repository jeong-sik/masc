(** The original child claim of one browser backend allocation: the host slot
    a Chrome or live Firefox owner holds, named by the cleanup descriptor the
    host recorded for that allocation. Blocking; the server caller offloads. *)
type t = { name : string; claim_directory : string; context : Yojson.Safe.t }
(** [name] is how refusals name the claim ("Chrome child claim").
    [context] is the descriptor this allocation recomputes. *)

val settled : name:string -> Native_addon_lease.t -> (unit, string) result
(** The claim is Settled. *)

val original : t -> (Native_addon_lease.t option, string) result
(** Reopen the slot under its gate. A missing slot, or one with no
    reservation, is [None]. A lone reservation that was never published is
    fenced as retired and returned. A claim whose descriptor differs belongs to
    another allocation and is refused. *)

val check_retained : t -> (unit, string) result
(** Read what {!original} reads, without its gate lock, fence or any write:
    the slot through [Native_addon_lease.inspect], and its descriptor compared
    with [context]. A missing slot is [Ok]. *)

val settle : t -> (unit, string) result
(** Recover the original claim: retire it, request termination by its kernel
    lease, and require Settled. A successful termination request alone does
    not establish cleanup. Never removes claims. *)

val check_settled : t -> (unit, string) result
(** Require that the original claim is already Settled, without retiring,
    fencing or signalling anything. A missing slot is [Ok]. A slot that is not
    one published claim is refused; the refusal says that a reservation that
    was never published is fenced by the next cleanup pass. *)
