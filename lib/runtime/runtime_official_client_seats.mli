(** Seats of official client accounts.

    An official client binding declares [max-concurrent]: how many client
    processes of its account may run at once. One provider is one account,
    so every binding of a provider that declares the number declares the
    same one. An account whose bindings declare a number has one scheduler
    while the server runs; an exact walk takes its seats from it
    ({!Llm_provider.Provider_admission.Scheduler_seats}). A binding without
    a declaration adds nothing to its account.

    RFC exact-lane-walks-one-slot-list section 3.6. *)

(** One official client runtime whose binding declares [max-concurrent]. *)
type declaration =
  { runtime_id : string
  ; provider_id : string
  ; max_concurrent : int
  }

(** The runtimes of one account (its provider id) that declare different
    numbers, each with what it declared, in the order given. *)
type disagreement =
  { account : string
  ; declarations : (string * int) list
  }

(** One agreed number per account, ready to publish. *)
type published

val of_declarations : declaration list -> (published, disagreement list) result
(** The number each account declares, or every account whose runtimes
    disagree, in the order the accounts first appear. *)

val publish : published -> unit
(** Make each account's number its scheduler's allowance. A new account
    gets a scheduler. An existing one is reconfigured when its number
    changed, so a seat taken before goes back to the scheduler it came
    from. Accounts left out keep their scheduler as it is. *)

val scheduler : provider_id:string -> Llm_provider.Slot_scheduler.t option
(** The account's scheduler, or [None] when no publish named the account. *)
