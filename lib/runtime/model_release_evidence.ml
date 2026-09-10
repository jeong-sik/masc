let ( let* ) = Result.bind

type date =
  { year : int
  ; month : int
  ; day : int
  }

let date_to_string date = Printf.sprintf "%04d-%02d-%02d" date.year date.month date.day

let date_of_string text =
  let digits part =
    String.for_all
      (function
        | '0' .. '9' -> true
        | _ -> false)
      part
  in
  match String.split_on_char '-' text with
  | [ year; month; day ]
    when String.length year = 4
         && String.length month = 2
         && String.length day = 2
         && digits year
         && digits month
         && digits day ->
    let year, month, day = int_of_string year, int_of_string month, int_of_string day in
    (match Ptime.of_date (year, month, day) with
     | Some _ when year >= 1 -> Ok { year; month; day }
     | Some _ | None -> Error "invalid calendar date")
  | _ -> Error "expected YYYY-MM-DD calendar date"
;;

let three_month_cutoff date =
  let year, month =
    if date.month > 3 then date.year, date.month - 3 else date.year - 1, date.month + 9
  in
  let last_day =
    if Ptime.of_date (year, month, 31) <> None
    then 31
    else if Ptime.of_date (year, month, 30) <> None
    then 30
    else if Ptime.of_date (year, month, 29) <> None
    then 29
    else 28
  in
  { year; month; day = min date.day last_day }
;;

let compare_date left right =
  compare (left.year, left.month, left.day) (right.year, right.month, right.day)
;;

type release_kind =
  | General_availability
  | Limited_release
  | Preview

type release =
  | Unknown
  | Official of
      { released_on : date
      ; kind : release_kind
      ; source_url : string
      ; checked_on : date
      }

type recency =
  | Unknown_release
  | Future_release
  | Within_three_months
  | Older_release

let recency ~as_of = function
  | Unknown -> Unknown_release
  | Official evidence ->
    if compare_date evidence.released_on as_of > 0
    then Future_release
    else if compare_date evidence.released_on (three_month_cutoff as_of) >= 0
    then Within_three_months
    else Older_release
;;

let recency_name = function
  | Unknown_release -> "unknown"
  | Future_release -> "future_release"
  | Within_three_months -> "within_three_calendar_months"
  | Older_release -> "older"
;;

let kind_name = function
  | General_availability -> "general_availability"
  | Limited_release -> "limited_release"
  | Preview -> "preview"
;;

type entry =
  { publisher : string
  ; model_id : string
  ; release : release
  }

type t = entry list

let object_fields expected = function
  | `Assoc fields
    when List.sort String.compare (List.map fst fields)
         = List.sort String.compare expected -> Ok fields
  | _ -> Error "unexpected or duplicate release evidence fields"
;;

let text fields name =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value = value && value <> "" -> Ok value
  | _ -> Error ("missing release evidence " ^ name)
;;

let release_of_json = function
  | `Assoc [ ("status", `String "unknown") ] -> Ok Unknown
  | json ->
    let* fields =
      object_fields [ "status"; "released_on"; "kind"; "source_url"; "checked_on" ] json
    in
    let* status = text fields "status" in
    if status <> "official_release"
    then Error "release evidence must identify official_release"
    else
      let* raw = text fields "released_on" in
      let* released_on = date_of_string raw in
      let* raw = text fields "checked_on" in
      let* checked_on = date_of_string raw in
      let* raw = text fields "kind" in
      let* kind =
        match raw with
        | "general_availability" -> Ok General_availability
        | "limited_release" -> Ok Limited_release
        | "preview" -> Ok Preview
        | _ -> Error "unknown release kind"
      in
      let* source_url = text fields "source_url" in
      let uri = Uri.of_string source_url in
      if
        Uri.scheme uri <> Some "https"
        || Uri.host uri = None
        || Uri.userinfo uri <> None
        || Uri.query uri <> []
        || Uri.fragment uri <> None
      then Error "release source must be a public HTTPS URL"
      else if compare_date checked_on released_on < 0
      then Error "release evidence checked before release date"
      else Ok (Official { released_on; kind; source_url; checked_on })
;;

let of_json json =
  let* fields = object_fields [ "schema"; "models" ] json in
  let* schema = text fields "schema" in
  if schema <> "masc.model_release_evidence.v1"
  then Error "unknown release evidence schema"
  else (
    match List.assoc_opt "models" fields with
    | Some (`List rows) ->
      List.fold_left
        (fun acc row ->
           let* entries = acc in
           let* fields = object_fields [ "publisher"; "model_id"; "release" ] row in
           let* publisher = text fields "publisher" in
           let* model_id = text fields "model_id" in
           let* release = release_of_json (List.assoc "release" fields) in
           if
             List.exists
               (fun entry -> entry.publisher = publisher && entry.model_id = model_id)
               entries
           then Error "duplicate model release identity"
           else Ok ({ publisher; model_id; release } :: entries))
        (Ok [])
        rows
    | _ -> Error "models must be a list")
;;

let lookup entries ~publisher ~model_id =
  match
    List.find_opt
      (fun entry -> entry.publisher = publisher && entry.model_id = model_id)
      entries
  with
  | None -> Unknown
  | Some entry -> entry.release
;;

let load_default () =
  match Embedded_config.read "model-releases.json" with
  | None -> Error "embedded model release evidence unavailable"
  | Some contents ->
    (try of_json (Yojson.Safe.from_string contents) with
     | Yojson.Json_error _ -> Error "invalid embedded model release evidence")
;;

let to_json ~as_of release =
  let fields =
    match release with
    | Unknown -> [ "status", `String "unknown" ]
    | Official evidence ->
      [ "status", `String "official_release"
      ; "released_on", `String (date_to_string evidence.released_on)
      ; "kind", `String (kind_name evidence.kind)
      ; "source_url", `String evidence.source_url
      ; "checked_on", `String (date_to_string evidence.checked_on)
      ]
  in
  `Assoc
    (fields
     @ [ "recency", `String (recency_name (recency ~as_of release))
       ; "as_of", `String (date_to_string as_of)
       ; "account_availability", `String "not_checked"
       ])
;;
