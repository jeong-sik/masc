module Usage = Runtime_provider_usage_window

module Projection = Server_provider_usage_history_projection

let store config =
  Dated_jsonl.open_store
    (Dated_jsonl.Store.at
       (Workspace_utils.dated_store_root config)
       Dated_jsonl.Store.Root.Provider_usage_history)

let scope_id = Runtime_quota_window.scope_id

let install config =
  let journal = store config in
  Usage.set_record_observer (fun ~scope ~observed_at report ->
    Dated_jsonl.append journal
      (`List (Projection.record_json ~scope_id:(scope_id scope) ~observed_at report)))

type window = One_day | Seven_days | Fourteen_days

let window_of_days = function
  | 1 -> Some One_day
  | 7 -> Some Seven_days
  | 14 -> Some Fourteen_days
  | _ -> None

let days_of_window = function
  | One_day -> 1
  | Seven_days -> 7
  | Fourteen_days -> 14

let window_start ~now ~window =
  (floor (now /. 86400.0) -. float_of_int (days_of_window window - 1)) *. 86400.0

let failure_in_window ~now ~window =
  match Usage.record_observer_failure_at () with
  | Some at -> at >= window_start ~now ~window && at <= now
  | None -> false

(* A stored line that cannot be read is logged with its place and counted in
   the answer, and the rest of the window is still read: one bad line is one
   unknown report, not fourteen unknown days. The count is the evidence that
   something is missing, so the reader never takes a gap for a quiet day. *)
let read config ~now ~window =
  if failure_in_window ~now ~window then
    Error "provider usage history incomplete: a report could not be stored"
  else
    let since_at = window_start ~now ~window in
    let journal = store config in
    (* The callback owns one accumulator cell; all history decisions return
       a new immutable projection. Diagnostics stay in traversal order. *)
    let projection = ref (Projection.create ~since_at ~now) in
    let skip ~where detail =
      Log.Server.warn "provider usage history unreadable report: %s: %s" where
        detail;
      projection := Projection.note_unreadable !projection
    in
    let consume = function
      | Dated_jsonl.Malformed_json { path; line_number; detail } ->
          skip
            ~where:
              (Printf.sprintf "%s:%s" path
                 (Option.fold ~none:"?" ~some:string_of_int line_number))
            detail
      | Dated_jsonl.Parsed (`List items) ->
          List.iter
            (fun item ->
              match Projection.consume_item !projection item with
              | Error detail -> skip ~where:"stored report" detail
              | Ok next -> projection := next)
            items
      | Dated_jsonl.Parsed _ ->
          skip ~where:"stored line" "expected a report list"
    in
    let result =
      Dated_jsonl.iter_range_entries_result journal
        ~since:(Log.format_utc_date_of since_at)
        ~until:(Log.format_utc_date_of now) consume
    in
    match result with
    | Error read_error ->
        Log.Server.warn "provider usage history read failed: %s"
          (Dated_jsonl.read_error_to_string read_error);
        Error "provider usage history store unavailable"
    | Ok () ->
        Ok (Projection.response_json ~days:(days_of_window window) !projection)
