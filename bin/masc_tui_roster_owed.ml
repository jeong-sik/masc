module Owed = Masc_tui_owed_read
module Names = Map.Make (String)

(* [scheduled] holds the rows to read at a time on the caller's clock, for a
   value that changes with time rather than with a write. *)
type t = { roster : Owed.t; rows : Owed.t Names.t; scheduled : float Names.t }

type read =
  | Read_row of string
  | Read_roster

let settled = { roster = Owed.settled; rows = Names.empty; scheduled = Names.empty }

let is_reading = function
  | Owed.Reading _ -> true
  | Owed.Settled | Owed.Owed _ | Owed.Waiting _ -> false

let is_settled = function
  | Owed.Settled -> true
  | Owed.Owed _ | Owed.Reading _ | Owed.Waiting _ -> false

(* A settled row owes nothing, so it is not kept. *)
let prune rows = Names.filter (fun _ owed -> not (is_settled owed)) rows

let row keeper_name t =
  Option.value (Names.find_opt keeper_name t.rows) ~default:Owed.settled

let with_row keeper_name owed t = { t with rows = prune (Names.add keeper_name owed t.rows) }

let row_changed ~keeper_name t = with_row keeper_name (Owed.changed (row keeper_name t)) t

let roster_changed t = { t with roster = Owed.changed t.roster }

let reading t = is_reading t.roster || Names.exists (fun _ owed -> is_reading owed) t.rows

(* A failed whole read dropped the roster a row would go into, and the whole
   read that follows its wait reads every owed row. *)
let waiting_out_a_failure ~now = function
  | Owed.Waiting { retry_at; _ } -> now < retry_at
  | Owed.Settled | Owed.Owed _ | Owed.Reading _ -> false

let next_read ~now t =
  if reading t || waiting_out_a_failure ~now t.roster then None
  else
    let due = Names.filter (fun _ owed -> Owed.due ~now owed) t.rows in
    match Owed.due ~now t.roster, Names.bindings due with
    | true, _ | false, _ :: _ :: _ -> Some Read_roster
    | false, [ (keeper_name, _) ] -> Some (Read_row keeper_name)
    | false, [] -> None

(* A whole read reads every row, so every owed row starts and settles with
   it. *)
let started read t =
  match read with
  | Read_roster -> { t with roster = Owed.started t.roster; rows = Names.map Owed.started t.rows }
  | Read_row keeper_name -> with_row keeper_name (Owed.started (row keeper_name t)) t

let succeeded read t =
  match read with
  | Read_roster ->
      { t with roster = Owed.succeeded t.roster; rows = prune (Names.map Owed.succeeded t.rows) }
  | Read_row keeper_name -> with_row keeper_name (Owed.succeeded (row keeper_name t)) t

let failed ~retry_s ~max_retry_s ~now read t =
  let fail = Owed.failed ~retry_s ~max_retry_s ~now in
  match read with
  | Read_roster -> { t with roster = fail t.roster; rows = Names.map fail t.rows }
  | Read_row keeper_name -> with_row keeper_name (fail (row keeper_name t)) t

let abandoned t =
  { t with roster = Owed.abandoned t.roster; rows = Names.map Owed.abandoned t.rows }

let schedule_rows due t =
  { t with
    scheduled =
      List.fold_left (fun scheduled (keeper_name, at) -> Names.add keeper_name at scheduled)
        Names.empty due
  }

let release_scheduled ~now t =
  let due, later = Names.partition (fun _ at -> at <= now) t.scheduled in
  Names.fold (fun keeper_name _ t -> row_changed ~keeper_name t) due { t with scheduled = later }
