(** The last wake of one Keeper, told from one page of its schedules
    (RFC-0515 section 2.5).

    Every schedule row carries the newest wake of its own instance
    ([sch_last_wake_*]). The Keeper's last wake is the latest of those, whether
    or not the schedule that recorded it is still live. A page the server cut
    does not hold every schedule, and a wake whose time cannot be read cannot be
    placed among the others, so the answer says which of those it is. *)

type t
(** A wake that was placed in time. *)

val row : t -> Masc_tui_types.schedule_row
(** The schedule that woke the Keeper. *)

val at : t -> float
(** When that wake started, in Unix seconds. *)

type reading =
  | No_wake  (** The page is whole and no schedule on it has woken the Keeper. *)
  | Not_on_first_page
      (** The page is cut and no schedule on it has woken the Keeper; a later
          page may hold one. *)
  | Newest of t  (** The page is whole: this is the Keeper's last wake. *)
  | Newest_on_first_page of t
      (** The page is cut: this is the latest wake on it, and a later page may
          hold a newer one. *)
  | Unplaced
      (** A schedule has a wake whose time is missing or not RFC 3339. Which
          wake is the last is not known, whatever else the page holds. *)

val of_page : truncated:bool -> Masc_tui_types.schedule_row list -> reading
(** The reading of a page of schedule rows. [truncated] is the page's own
    [scs_truncated]. On equal instants the row that comes first wins. *)
