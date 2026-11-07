type bin =
  | Under_hour
  | Under_day
  | Under_week
  | Older

type t =
  { under_hour : int
  ; under_day : int
  ; under_week : int
  ; older : int
  }

let zero =
  { under_hour = 0
  ; under_day = 0
  ; under_week = 0
  ; older = 0
  }
;;

let classify ~now ts =
  let age = if ts > now then 0.0 else now -. ts in
  if age < Masc_time_constants.hour
  then Under_hour
  else if age < Masc_time_constants.day
  then Under_day
  else if age < Masc_time_constants.days_to_seconds 7
  then Under_week
  else Older
;;

let of_first_seen ~now timestamps =
  List.fold_left
    (fun acc ts ->
      match classify ~now ts with
      | Under_hour -> { acc with under_hour = acc.under_hour + 1 }
      | Under_day -> { acc with under_day = acc.under_day + 1 }
      | Under_week -> { acc with under_week = acc.under_week + 1 }
      | Older -> { acc with older = acc.older + 1 })
    zero
    timestamps
;;

let total t = t.under_hour + t.under_day + t.under_week + t.older

let to_json t =
  `Assoc
    [ "under_hour", `Int t.under_hour
    ; "under_day", `Int t.under_day
    ; "under_week", `Int t.under_week
    ; "older", `Int t.older
    ]
;;

let of_json = function
  | `Assoc fields ->
    let get_int name =
      match List.assoc_opt name fields with
      | Some (`Int i) when i >= 0 -> Ok i
      | Some (`Int _) -> Error (Printf.sprintf "field %S must be non-negative" name)
      | Some _ -> Error (Printf.sprintf "field %S must be an int" name)
      | None -> Error (Printf.sprintf "missing required field %S" name)
    in
    (match
       ( get_int "under_hour"
       , get_int "under_day"
       , get_int "under_week"
       , get_int "older" )
     with
     | Ok under_hour, Ok under_day, Ok under_week, Ok older ->
       Ok { under_hour; under_day; under_week; older }
     | Error err, _, _, _
     | _, Error err, _, _
     | _, _, Error err, _
     | _, _, _, Error err -> Error err)
  | other ->
    Error
      (Printf.sprintf
         "expected age_bins object, got %s"
         (Yojson.Safe.to_string other))
;;
