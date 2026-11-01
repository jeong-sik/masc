module Decode = Fixture_types.Decode
type liveness = Fixture_types.Control.liveness =
  | Unobserved | Invalid of string | Absent | Present of Decode.keeper_runtime
type reading = Fixture_types.Control.reading =
  { name : string; paused : bool; liveness : liveness }
type roster =
  | Roster_unobserved
  | Roster_partial of
      { observed : Decode.keeper_runtime list
      ; total : int
      }
  | Roster_invalid of
      { observed : Decode.keeper_runtime list
      ; errors : (string * string) list
      ; complete : bool
      }
  | Roster_complete of Decode.keeper_runtime list

let roster_of_reading ~errors ~rows ~truncated ~total =
  (* [count] short of [total] is the same fact as truncation: rows that belong
     here are missing. The route drops a keeper whose metadata it cannot read,
     and that keeper's fiber is still running. *)
  let observed_count = List.length rows in
  if errors <> [] then
    Roster_invalid { observed = rows; errors;
      complete = not truncated && observed_count + List.length errors >= total }
  else if truncated || observed_count < total then
    Roster_partial { observed = rows; total = max total observed_count }
  else Roster_complete rows

let find_row rows name =
  List.find_opt
    (fun (row : Decode.keeper_runtime) -> String.equal row.kr_name name)
    rows

let liveness_of_roster roster name =
  match roster with
  | Roster_invalid { observed; errors; complete } -> (
      match List.assoc_opt name errors with
      | Some detail -> Invalid detail
      | None -> (match find_row observed name with
          | Some row -> Present row
          | None -> if complete then Absent else Unobserved))
  | Roster_unobserved -> Unobserved
  | Roster_partial { observed; total = _ } -> (
      match find_row observed name with
      | Some row -> Present row
      | None ->
          (* Rows are missing from this roster, so this name may be one of
             them. That is not evidence of a stopped fiber. *)
          Unobserved)
  | Roster_complete rows -> (
      match find_row rows name with
      | Some row -> Present row
      | None -> Absent)


type action = Fixture_types.Control.action =
  | Pause
  | Resume
  | Boot
  | Shutdown
  | Wakeup
  | Delete

let runs reading =
  match reading.liveness with
  | Unobserved | Invalid _ -> None
  | Absent -> Some false
  | Present runtime -> Some runtime.Decode.kr_keepalive_running

(* Confirmed deletion uses the server's durable shutdown operation, which
   stops and joins the exact lane before removing its artifacts. *)
let available reading =
  match runs reading with
  | None -> [ Delete ]
  | Some false -> [ Boot; Delete ]
  | Some true ->
      if reading.paused then [ Resume; Wakeup; Shutdown; Delete ]
      else [ Pause; Wakeup; Shutdown; Delete ]

