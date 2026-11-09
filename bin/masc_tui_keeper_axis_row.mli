(** Which cells a Keepers row draws in each view (RFC-0515 §2.4, E16).

    Every view but [Plain] draws a Keeper on the grid (§2.4.1): ◂ what came
    before, ● what it does now, ▹ what comes next, on columns fixed from the
    right edge. A view picks what the columns draw. A view with values of its
    own adds a constructor to {!columns} and changes only its own arm of
    {!shape_of_view}. *)

(** What the columns of the grid draw. *)
type columns =
  | Activity_columns
      (** The pulse, the activity mark and word, the half hours ahead, the next
          scheduled run and the librarian lag. *)
  | Memory_columns
      (** The pulse, how the librarian's last pass ended, the unread turns as a
          bar, the time since the last digest and the atoms requests skip. *)
  | Age_columns
      (** The facts by age, the time since the memory last changed, the unread
          turns as a bar, the invalidated sources and the fact count. *)

type shape =
  | List_columns  (** The list's columns: NOW, Mode S, AGE, LIFECYCLE / RUNTIME, DETAIL. *)
  | Grid of columns

val shape_of_view : Masc_tui_keeper_list_model.view -> shape
(** The memory and age views draw columns of their own. The other views but
    the list draw the activity columns. *)

type second_line =
  | No_second_line
  | List_detail  (** The list's second line: attempt chain, detail and cells. *)
  | Failure_chain
      (** When the failing phase began, the attempts of the failed turn and the
          runtime of the next dispatch (§2.4.6). *)

val second_line :
  Masc_tui_keeper_list_model.view ->
  Masc_tui_keeper_list_model.density ->
  Masc_tui_keeper_trail.trail ->
  second_line
(** One line draws no second line. Two lines draw the list's second line under
    every list row. The state and cause views draw one under a Keeper whose
    trail is failed; the other views keep every Keeper on one line. *)
