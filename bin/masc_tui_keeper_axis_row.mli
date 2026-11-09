(** Which cells a Keepers row draws in each view (RFC-0515 §2.4, E16).

    Every view but [Plain] draws a Keeper on one axis row of three cells:
    ◂ what came before, ● what it does now, ▹ what comes next. The frame of
    the three cells is the same in every view; the view picks the value each
    cell draws. A view with values of its own adds constructors here and
    changes only its own arm of {!shape_of_view}. *)

type before =
  | Hour_pulse  (** The turn pulse, one mark per clock hour, newest on the right. *)
  | Fact_ages  (** The Keeper's facts counted into the server's four age bins. *)

type current =
  | Activity  (** The activity mark and word the list draws under NOW. *)
  | Librarian_pass  (** How the librarian's last pass ended. *)
  | Update_age  (** How long ago the Keeper's memory snapshot last changed. *)

type next =
  | Wait_run_path_lag
      (** What the Keeper waits on a person for, the next scheduled run, the
          rest of the next dispatch path, and the turns the librarian has not
          read. *)
  | Lag_digest_gap
      (** The unread turns as a bar, the time since the librarian's last
          digest, and the atoms requests skip. *)
  | Lag_stale_facts
      (** The unread turns as a bar, the invalidated sources, and the fact
          count. *)

type axis = { before : before; current : current; next : next }

type shape =
  | List_columns  (** The list's columns: NOW, Mode S, AGE, LIFECYCLE / RUNTIME, DETAIL. *)
  | Axis of axis

val shape_of_view : Masc_tui_keeper_list_model.view -> shape
(** The memory view draws the pulse, the librarian's last pass and how far
    it trails; the age view draws the facts by age, the last change and how
    far the librarian trails. The other views draw the pulse, the activity and
    what comes next. *)

type second_line =
  | No_second_line
  | List_detail  (** The list's second line: attempt chain, detail and cells. *)
  | Failure_chain  (** The last failure's sentence and the attempts of that turn. *)

val second_line :
  shape -> Masc_tui_keeper_list_model.density -> Masc_tui_keeper_trail.trail -> second_line
(** One line draws no second line. Two lines draw the list's second line under
    every list row, and under an axis row only when the trail is failed: a
    Keeper that is not failing keeps one line. *)
