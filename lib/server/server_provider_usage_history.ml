module Usage = Runtime_provider_usage_window

module Projection = Server_provider_usage_history_projection

open Result.Syntax

let store config =
  Dated_jsonl.open_store
    (Dated_jsonl.Store.at
       (Workspace_utils.dated_store_root config)
       Dated_jsonl.Store.Root.Provider_usage_history)

let scope_id = Runtime_quota_window.scope_id

let install config =
  let journal = store config in
  Usage.set_record_observer (fun ~scope ~observed_at report ->
    (* The record and its announcement go out together: a report that lands
      while a reader watches is told to the readers of this dataset, whatever
      the append did. *)
    Fun.protect
      ~finally:(fun () ->
        Eio.Cancel.protect (fun () ->
          Workspace_dataset_event.announce ~base_path:config.Workspace.base_path
            Workspace_dataset_event.Provider_usage))
      (fun () ->
        Dated_jsonl.append journal
          (`List (Projection.record_json ~scope_id:(scope_id scope) ~observed_at report))))

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
   something is missing, so the reader never takes a gap for a quiet day. A
   line is logged once, when its file is first read up to it. *)
let consume projection = function
  | Dated_jsonl.Malformed_json { path; line_number; detail } ->
      Log.Server.warn "provider usage history unreadable report: %s:%s: %s" path
        (Option.fold ~none:"?" ~some:string_of_int line_number)
        detail;
      Projection.note_unreadable projection
  | Dated_jsonl.Parsed (`List items) ->
      List.fold_left
        (fun projection item ->
          match Projection.consume_item projection item with
          | Ok next -> next
          | Error detail ->
              Log.Server.warn "provider usage history unreadable report: stored report: %s"
                detail;
              Projection.note_unreadable projection)
        projection items
  | Dated_jsonl.Parsed _ ->
      Log.Server.warn "provider usage history unreadable report: stored line: %s"
        "expected a report list";
      Projection.note_unreadable projection

module Kept = Dated_jsonl_kept_days

(* Each journal day file of the widest window, folded into its latest reading
   per source, day and window and kept between reads: a read folds only what
   the files gained since the last one, and a narrower window absorbs the
   files of its own days. *)
let kept : (string, Projection.t Kept.t) Hashtbl.t = Hashtbl.create 1
let kept_mu = Stdlib.Mutex.create ()

(* The day files of the widest window, folded and kept for the workspace. *)
let kept_days config ~now =
  let days =
    Kept.days_between ~since:(window_start ~now ~window:Fourteen_days) ~until:now
  in
  let previous =
    Stdlib.Mutex.protect kept_mu (fun () ->
      Option.value ~default:Kept.empty (Hashtbl.find_opt kept config.Workspace.base_path))
  in
  match
    Kept.refresh (store config) ~days ~init:(Projection.unbounded ()) ~f:consume previous
  with
  | Error read_error ->
      Log.Server.warn "provider usage history read failed: %s"
        (Dated_jsonl.read_error_to_string read_error);
      Error "provider usage history store unavailable"
  | Ok files ->
      Stdlib.Mutex.protect kept_mu (fun () ->
        Hashtbl.replace kept config.Workspace.base_path files);
      Ok files

let project files ~now ~window =
  let since_at = window_start ~now ~window in
  Kept.fold files ~init:(Projection.create ~since_at ~now)
    ~f:(fun projection (day : Kept.day) file ->
      if day.starts_at >= since_at then Projection.absorb projection file
      else projection)

let read config ~now ~window =
  if failure_in_window ~now ~window then
    Error "provider usage history incomplete: a report could not be stored"
  else
    let* files = kept_days config ~now in
    Ok (Projection.response_json ~days:(days_of_window window) (project files ~now ~window))

let restore config ~now ~scopes =
  let* files = kept_days config ~now in
  let stored = Projection.stored_reports (project files ~now ~window:Fourteen_days) in
  if stored.Projection.unrestorable > 0 then
    Log.Server.warn
      "provider usage history: %d stored readings name a source or kind this build does not write and were not put back"
      stored.Projection.unrestorable;
  List.iter
    (fun scope ->
      let id = scope_id scope in
      Usage.restore ~scope ~now
        (List.filter_map
           (fun (scope_id, observed_at, report) ->
             if String.equal scope_id id then Some (observed_at, report) else None)
           stored.Projection.reports))
    scopes;
  Ok ()
