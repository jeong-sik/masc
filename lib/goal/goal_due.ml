(* See goal_due.mli. *)

type t =
  | No_due_date
  | Due_date of
      { date : Ptime.date
      ; instant : Ptime.t
      }
  | Unreadable_due_date of string

(* A due date falls due at the last second of its day, in UTC. *)
let last_second_of_the_day : Ptime.time = ((23, 59, 59), 0)

let year_digits = 4
let month_digits = 2
let day_digits = 2

let is_digit c = c >= '0' && c <= '9'

(* [int_of_string_opt] alone would take "+5", "0x1f" and "1_0"; requiring every
   character to be a digit and the exact width is what makes this strict. *)
let number ~digits part =
  if String.length part = digits && String.for_all is_digit part
  then int_of_string_opt part
  else None
;;

let read_date raw =
  match String.split_on_char '-' raw with
  | [ year; month; day ] ->
    let ( let* ) = Option.bind in
    let* year = number ~digits:year_digits year in
    let* month = number ~digits:month_digits month in
    let* day = number ~digits:day_digits day in
    Some (year, month, day)
  | [] | [ _ ] | [ _; _ ] | _ :: _ :: _ :: _ :: _ -> None
;;

let read = function
  | None -> No_due_date
  | Some raw ->
    (match read_date raw with
     | None -> Unreadable_due_date raw
     | Some date ->
       (* [Ptime.of_date_time] is what refuses 2026-13-01 and 2026-02-30. *)
       (match Ptime.of_date_time (date, last_second_of_the_day) with
        | None -> Unreadable_due_date raw
        | Some instant -> Due_date { date; instant }))
;;
