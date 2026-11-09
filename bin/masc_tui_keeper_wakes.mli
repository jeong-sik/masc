(** The wakes of one Keeper, told from one page of its schedules
    (RFC-0515 section 2.5).

    Every schedule row carries the newest wake of its own instance
    ([sch_last_wake_*]). The Keeper's wakes are those, whether or not the
    schedule that recorded one is still live, so the page holds at most one
    wake per schedule and not every wake the Keeper ever had. A page the server
    cut does not hold every schedule, and a wake whose time cannot be read
    cannot be placed among the others, so the answer says which of those it
    is. *)

type t
(** A wake that was placed in time. *)

val row : t -> Masc_tui_types.schedule_row
(** The schedule that woke the Keeper. *)

val at : t -> float
(** When that wake started, in Unix seconds. *)

type coverage =
  | Whole_page  (** The page holds every schedule of the Keeper. *)
  | First_page  (** The page is cut: a later page may hold a newer wake. *)

type reading =
  | Wakes of
      { newest_first : t list
      ; coverage : coverage
      }
      (** Every wake the page holds, newest first. Empty when no schedule on
          the page has woken the Keeper. *)
  | Unplaced
      (** A schedule has a wake whose time is missing or not RFC 3339. Which
          wakes are the newest is not known, whatever else the page holds. *)

val of_page : truncated:bool -> Masc_tui_types.schedule_row list -> reading
(** The reading of a page of schedule rows. [truncated] is the page's own
    [scs_truncated]. On equal instants the row that comes first wins. *)
