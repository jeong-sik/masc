module Decode = Fixture_types.Decode
type liveness = Fixture_types.Control.liveness =
  | Unobserved | Invalid of string | Absent | Present of Decode.keeper_runtime
type reading = Fixture_types.Control.reading =
  { name : string; paused : bool; liveness : liveness }
type roster_view =
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

module Roster_names = Map.Make (String)

type roster = { source : roster_view; names : liveness Roster_names.t }

let unobserved_roster = { source = Roster_unobserved; names = Roster_names.empty }

let roster_view roster = roster.source

let prepare_roster source =
  let observed, errors =
    match source with
    | Roster_unobserved -> [], []
    | Roster_partial { observed; total = _ }
    | Roster_complete observed -> observed, []
    | Roster_invalid { observed; errors; complete = _ } -> observed, errors
  in
  let observed =
    List.fold_left
      (fun index (row : Decode.keeper_runtime) ->
        Roster_names.update row.kr_name
          (function None -> Some (Present row) | Some _ as first -> first) index)
      Roster_names.empty observed
  in
  let errors =
    List.fold_left
      (fun index (name, detail) ->
        Roster_names.update name
          (function None -> Some (Invalid detail) | Some _ as first -> first) index)
      Roster_names.empty errors
  in
  { source; names = Roster_names.union (fun _ error _ -> Some error) errors observed }

let roster_of_reading ~errors ~rows ~truncated ~total =
  (* [count] short of [total] is the same fact as truncation: rows that belong
     here are missing. The route drops a keeper whose metadata it cannot read,
     and that keeper's fiber is still running. *)
  let observed_count = List.length rows in
  let source =
    if errors <> [] then
      Roster_invalid { observed = rows; errors;
        complete = not truncated && observed_count + List.length errors >= total }
    else if truncated || observed_count < total then
      Roster_partial { observed = rows; total = max total observed_count }
    else Roster_complete rows
  in
  prepare_roster source

let liveness_of_roster roster name =
  match Roster_names.find_opt name roster.names with
  | Some reading -> reading
  | None ->
      match roster.source with
      | Roster_unobserved | Roster_partial _ -> Unobserved
      | Roster_complete _ -> Absent
      | Roster_invalid { complete; _ } -> if complete then Absent else Unobserved


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

