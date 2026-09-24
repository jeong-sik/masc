(** Provider-reported usage windows.  See the [.mli] for the contract. *)

type window_kind =
  | Five_hour
  | Seven_day
  | Duration_minutes of int
  | Provider_label of string

type utilization =
  | Fraction of float
  | Percent of int

type source =
  | Claude_code_rate_limit_event
  | Codex_account_rate_limits_updated

type window =
  { limit_id : string option
  ; kind : window_kind
  ; utilization : utilization
  ; resets_at : int option
  }

type report =
  { source : source
  ; windows : window list
  }

type decode_error =
  | Expected_object of { path : string }
  | Missing_field of { path : string }
  | Wrong_type of
      { path : string
      ; expected : string
      }

let decode_error_to_string = function
  | Expected_object { path } -> Printf.sprintf "%s must be an object" path
  | Missing_field { path } -> Printf.sprintf "%s is missing" path
  | Wrong_type { path; expected } -> Printf.sprintf "%s must be %s" path expected
;;

let source_to_string = function
  | Claude_code_rate_limit_event -> "claude_code.rate_limit_event"
  | Codex_account_rate_limits_updated -> "codex.account_rate_limits_updated"
;;

let ( let* ) = Result.bind

let fields_at ~path = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Expected_object { path })
;;

let member_path path name = path ^ "." ^ name

let required ~path name fields =
  match List.assoc_opt name fields with
  | Some json -> Ok json
  | None -> Error (Missing_field { path = member_path path name })
;;

(* Absent and null both mean the provider stated no value. *)
let optional_int ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (Wrong_type { path = member_path path name; expected = "an integer or null" })
;;

let optional_string ~path name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Wrong_type { path = member_path path name; expected = "a string or null" })
;;

let map_result f items =
  List.fold_right
    (fun item acc ->
       let* rest = acc in
       let* value = f item in
       Ok (value :: rest))
    items
    (Ok [])
;;

(* Claude Code names the windows by key.  Only the two keys observed on the
   wire have names here; anything else keeps the provider's own label. *)
let claude_window_kind = function
  | "five_hour" -> Five_hour
  | "seven_day" -> Seven_day
  | label -> Provider_label label
;;

let claude_window ~path (key, json) =
  let path = member_path path key in
  let* fields = fields_at ~path json in
  let* utilization =
    let* value = required ~path "utilization" fields in
    match value with
    | `Float fraction -> Ok (Fraction fraction)
    | `Int whole -> Ok (Fraction (Float.of_int whole))
    | _ ->
      Error (Wrong_type { path = member_path path "utilization"; expected = "a number" })
  in
  let* resets_at = optional_int ~path "resetsAt" fields in
  Ok { limit_id = None; kind = claude_window_kind key; utilization; resets_at }
;;

let decode_claude_rate_limit_event json =
  let path = "rate_limit_event" in
  let* fields = fields_at ~path json in
  let* info = required ~path "rate_limit_info" fields in
  let path = member_path path "rate_limit_info" in
  let* info_fields = fields_at ~path info in
  let* windows =
    match List.assoc_opt "unifiedWindows" info_fields with
    | None | Some `Null -> Ok []
    | Some unified ->
      let path = member_path path "unifiedWindows" in
      let* entries = fields_at ~path unified in
      map_result (claude_window ~path) entries
  in
  Ok { source = Claude_code_rate_limit_event; windows }
;;

(* Window lengths, in minutes, that have a name.  Codex states the length of
   each window; these are exact lengths, not ranges. *)
let five_hour_minutes = 5 * 60
let seven_day_minutes = 7 * 24 * 60

let codex_window_kind ~slot = function
  | Some minutes when Int.equal minutes five_hour_minutes -> Five_hour
  | Some minutes when Int.equal minutes seven_day_minutes -> Seven_day
  | Some minutes -> Duration_minutes minutes
  | None -> Provider_label slot
;;

let codex_window ~path ~limit_id ~slot fields =
  match List.assoc_opt slot fields with
  | None | Some `Null -> Ok None
  | Some json ->
    let path = member_path path slot in
    let* window_fields = fields_at ~path json in
    let* used_percent =
      match List.assoc_opt "usedPercent" window_fields with
      | Some (`Int percent) -> Ok percent
      | Some _ ->
        Error (Wrong_type { path = member_path path "usedPercent"; expected = "an integer" })
      | None -> Error (Missing_field { path = member_path path "usedPercent" })
    in
    let* duration = optional_int ~path "windowDurationMins" window_fields in
    let* resets_at = optional_int ~path "resetsAt" window_fields in
    Ok
      (Some
         { limit_id
         ; kind = codex_window_kind ~slot duration
         ; utilization = Percent used_percent
         ; resets_at
         })
;;

let decode_codex_rate_limits_updated params =
  let path = "account/rateLimits/updated" in
  let* fields = fields_at ~path params in
  let* snapshot = required ~path "rateLimits" fields in
  let path = member_path path "rateLimits" in
  let* snapshot_fields = fields_at ~path snapshot in
  let* limit_id = optional_string ~path "limitId" snapshot_fields in
  let* primary = codex_window ~path ~limit_id ~slot:"primary" snapshot_fields in
  let* secondary = codex_window ~path ~limit_id ~slot:"secondary" snapshot_fields in
  Ok
    { source = Codex_account_rate_limits_updated
    ; windows = List.filter_map Fun.id [ primary; secondary ]
    }
;;

type recorded =
  { window : window
  ; source : source
  ; observed_at : float
  }

type scope_state =
  | Not_reported_since_start
  | Reported of recorded * recorded list

let recording_since = Time_compat.now ()

(* scope -> (limit_id, kind) -> latest recorded.  Guarded by a
   [Stdlib.Mutex] like {!Runtime_quota_window}: nothing inside the lock
   suspends. *)
let table : (Runtime_quota_window.scope, (string option * window_kind, recorded) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 4
;;

let mu = Stdlib.Mutex.create ()

let record ~scope ~observed_at (report : report) =
  match report.windows with
  | [] -> ()
  | windows ->
    Stdlib.Mutex.protect mu (fun () ->
      let by_window =
        match Hashtbl.find_opt table scope with
        | Some by_window -> by_window
        | None ->
          let by_window = Hashtbl.create 4 in
          Hashtbl.replace table scope by_window;
          by_window
      in
      List.iter
        (fun (window : window) ->
           let key = window.limit_id, window.kind in
           match Hashtbl.find_opt by_window key with
           | Some held when Float.compare held.observed_at observed_at > 0 -> ()
           | Some _ | None ->
             Hashtbl.replace by_window key { window; source = report.source; observed_at })
        windows)
;;

let kind_rank = function
  | Five_hour -> 0
  | Seven_day -> 1
  | Duration_minutes _ -> 2
  | Provider_label _ -> 3
;;

let compare_kind left right =
  match left, right with
  | Duration_minutes a, Duration_minutes b -> Int.compare a b
  | Provider_label a, Provider_label b -> String.compare a b
  | (Five_hour | Seven_day | Duration_minutes _ | Provider_label _), _ ->
    Int.compare (kind_rank left) (kind_rank right)
;;

let compare_recorded (left : recorded) (right : recorded) =
  match Option.compare String.compare left.window.limit_id right.window.limit_id with
  | 0 -> compare_kind left.window.kind right.window.kind
  | order -> order
;;

let state ~scope =
  let held =
    Stdlib.Mutex.protect mu (fun () ->
      match Hashtbl.find_opt table scope with
      | None -> []
      | Some by_window -> Hashtbl.fold (fun _ recorded acc -> recorded :: acc) by_window [])
  in
  match List.sort compare_recorded held with
  | [] -> Not_reported_since_start
  | first :: rest -> Reported (first, rest)
;;

let recorded_scopes () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.fold (fun scope _ acc -> scope :: acc) table [])
;;
