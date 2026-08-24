type scheduled_stat = {
  decision_count : int;
  latest_ts : string option;
  latest_ts_unix : float option;
  failure_count : int;
}

(* Where [first_ts] came from. The 24h persistence gate asks for the EARLIEST
   turn row in durable history, and a bounded tail read can never witness a
   minimum: the tail is by construction the newest slice. The origin is
   therefore recorded rather than assumed, so a reader can tell "no turn rows
   exist" apart from "turn rows exist but were not reached". *)
type first_ts_origin =
  | History_head of int option
      (** Earliest turn row located in the head of the oldest surviving
          decision-log segment. Carries that segment's rotation index;
          [None] denotes the unrotated current segment. *)
  | History_scan_exhausted of int option
      (** The segment head budget ended before a turn row was found. Carries
          the segment whose unscanned suffix may contain the earliest row. *)
  | No_turn_row_in_history
      (** Every surviving segment was scanned to EOF without a turn row. *)

type turn_span_stat = {
  recent_interaction_count : int;
      (** Turn rows inside the recent tail window only. This is a liveness
          signal, not a history total; [first_ts] deliberately comes from a
          different (oldest) segment. *)
  first_ts : float option;
  latest_ts : float option;
  first_ts_origin : first_ts_origin;
  segments_observed : int;
}

let seconds_per_hour = Masc_time_constants.hour
let persistent_turn_window_hours = 24.0
let recent_turn_max_age_hours = 24.0

type persistence_tier =
  { id : string
  ; required_span_hours : float
  }

let persistence_tiers =
  [ { id = "1h"; required_span_hours = 1.0 }
  ; { id = "2h"; required_span_hours = 2.0 }
  ; { id = "4h"; required_span_hours = 4.0 }
  ; { id = "24h"; required_span_hours = persistent_turn_window_hours }
  ]
;;

let decision_tail_max_bytes = 512 * 1024
let decision_tail_max_lines = 5000

(* Head budget for locating the earliest turn row in one segment. Measured
   2026-08-09 over the 8-keeper fleet: the first turn row sat within 7.6 KB of
   every segment head (worst case a live Keeper at row 4), so this clears the observed
   worst case by ~67x while keeping the read O(1) in file size. *)
let decision_head_max_bytes = 512 * 1024

let empty_scheduled_stat =
  { decision_count = 0; latest_ts = None; latest_ts_unix = None; failure_count = 0 }

(* Tail-window accumulator. Kept separate from [turn_span_stat] because the
   tail can only answer "how recent" — "how far back" is answered by the head
   scan below. *)
type tail_scan = { count : int; latest : float option }

let empty_tail_scan = { count = 0; latest = None }

let fold_keeper_decision_log ~config keeper_name ~init ~f =
  let path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  if not (Sys.file_exists path) then init
  else
    (match
       Keeper_memory.read_file_tail_lines_result path
         ~max_bytes:decision_tail_max_bytes
         ~max_lines:decision_tail_max_lines
     with
     | Ok lines -> lines
     | Error exn_class ->
         Keeper_memory.record_memory_recall_read_error
           ~site:"dashboard_decision_log_proof" path exn_class;
         [])
    |> List.fold_left
         (fun acc line ->
            let line = String.trim line in
            if line = "" then acc
            else
              match Yojson.Safe.from_string line with
              | exception Yojson.Json_error _ -> acc
              | json -> f acc json)
         init

let decision_ts_unix json =
  match Safe_ops.json_float_opt "ts_unix" json with
  | Some ts when ts > 0.0 -> Some ts
  | _ ->
    (match Safe_ops.json_string_opt "ts" json with
     | Some ts -> Masc_domain.parse_iso8601_opt ts
     | None -> None)

let scheduled_success json =
  Safe_ops.json_string_opt "outcome" json = Some "success"

let update_scheduled_latest stat json =
  match decision_ts_unix json with
  | None -> stat
  | Some ts ->
    (match stat.latest_ts_unix with
     | Some previous when previous >= ts -> stat
     | _ ->
       {
         stat with
         latest_ts_unix = Some ts;
         latest_ts = Some (Masc_domain.iso8601_of_unix_seconds ts);
       })

let scheduled_stats ~config keeper_name =
  fold_keeper_decision_log ~config keeper_name
    ~init:empty_scheduled_stat
    ~f:(fun acc json ->
      match Safe_ops.json_string_opt "channel" json with
      | Some "scheduled_autonomous" ->
        if scheduled_success json then
          update_scheduled_latest
            { acc with decision_count = acc.decision_count + 1 }
            json
        else
          { acc with failure_count = acc.failure_count + 1 }
      | _ -> acc)

let scheduled_evidence_json stat =
  `Assoc [
    ("decision_count", `Int stat.decision_count);
    ("failure_count", `Int stat.failure_count);
    ( "latest_ts_unix", Json_util.float_opt_to_json stat.latest_ts_unix );
    ( "latest_ts", Json_util.string_opt_to_json stat.latest_ts );
  ]

(* A turn-exchange row is any cycle whose channel parses to a known typed
   channel (Reactive / Scheduled_autonomous). Legacy spellings
   ("reactive"/"proactive") and the non-interaction "heartbeat" marker no
   longer count (RFC-0020 Phase 1 PR-3, owner decision 2026-06-15). *)
let is_turn_exchange_channel = function
  | Some s -> Option.is_some (Keeper_world_observation.channel_of_string s)
  | None -> false

let update_tail_scan scan ts =
  {
    count = scan.count + 1;
    latest =
      Some
        (match scan.latest with
         | Some latest -> max latest ts
         | None -> ts);
  }

(** Every decision-log segment for [keeper_name], oldest first. Rotation is a
    typed concept owned by {!Keeper_runtime_root_entry}; enumerating through
    that catalog keeps this reader in step with the writer instead of
    re-deriving a filename convention that only the writer knows. *)
let decision_log_segments ~config keeper_name =
  let current = Keeper_types_support.keeper_decision_log_path config keeper_name in
  let dir = Filename.dirname current in
  if not (Fs_compat.file_exists dir) then []
  else
    Fs_compat.read_dir dir
    |> List.filter_map (fun base ->
      Keeper_runtime_root_entry.classify_basename base
      |> List.find_map (function
        | Keeper_runtime_root_entry.Keeper
            { keeper_name = name
            ; artifact = Keeper_runtime_root_entry.Decision_log
            ; rotation
            }
          when String.equal name keeper_name ->
          Some (rotation, Filename.concat dir base)
        | _ -> None))
    |> List.sort (fun (left, _) (right, _) ->
      (* Oldest first: a higher rotation index is an older segment, and the
         unrotated current segment is the newest of all. *)
      match left, right with
      | Some left, Some right -> Int.compare right left
      | Some _, None -> -1
      | None, Some _ -> 1
      | None, None -> 0)

(** Earliest turn row inside the head budget of one segment. A head slice can
    end mid-row; unparseable lines are skipped exactly as on the tail path, so
    a truncated final line cannot fabricate a timestamp. *)
type segment_head_scan =
  | Turn_found of float
  | Complete_without_turn
  | Scan_exhausted

let earliest_turn_ts_in_segment ~now path =
  let slice = Fs_compat.read_slice ~path ~from:0 ~len:decision_head_max_bytes in
  let turn =
    String.split_on_char '\n' slice
    |> List.find_map (fun line ->
      let line = String.trim line in
      if String.equal line "" then None
      else
        match Yojson.Safe.from_string line with
        | exception Yojson.Json_error _ -> None
        | json ->
          if is_turn_exchange_channel (Safe_ops.json_string_opt "channel" json)
          then
            (match decision_ts_unix json with
             | Some ts when ts <= now -> Some ts
             | Some _ | None -> None)
          else None)
  in
  match turn with
  | Some ts -> Turn_found ts
  | None ->
    (match Fs_compat.file_size path with
     | Some size when size <= String.length slice -> Complete_without_turn
     | Some _ | None -> Scan_exhausted)

let earliest_turn_ts ~now segments =
  let rec scan = function
    | [] -> None, No_turn_row_in_history
    | (rotation, path) :: rest ->
      (match earliest_turn_ts_in_segment ~now path with
       | Turn_found ts -> Some ts, History_head rotation
       | Complete_without_turn -> scan rest
       | Scan_exhausted -> None, History_scan_exhausted rotation)
  in
  scan segments

let turn_span_stats ~config ~now keeper_name =
  let tail =
    fold_keeper_decision_log ~config keeper_name ~init:empty_tail_scan
      ~f:(fun scan json ->
        if is_turn_exchange_channel (Safe_ops.json_string_opt "channel" json) then
          match decision_ts_unix json with
          | Some ts when ts <= now -> update_tail_scan scan ts
          | Some _ -> scan
          | None -> scan
        else scan)
  in
  let segments = decision_log_segments ~config keeper_name in
  let first_ts, first_ts_origin = earliest_turn_ts ~now segments in
  {
    recent_interaction_count = tail.count;
    first_ts;
    latest_ts = tail.latest;
    first_ts_origin;
    segments_observed = List.length segments;
  }

let hours_between first latest =
  max 0.0 (latest -. first) /. seconds_per_hour

let latest_age_hours ~now latest =
  max 0.0 (now -. latest) /. seconds_per_hour

let unix_opt_to_json = function
  | Some ts when ts > 0.0 -> `Float ts
  | _ -> `Null

let unix_opt_to_iso_json = function
  | Some ts when ts > 0.0 ->
    `String (Masc_domain.iso8601_of_unix_seconds ts)
  | _ -> `Null

let turn_span_hours_json stat =
  match stat.first_ts, stat.latest_ts with
  | Some first, Some latest -> `Float (hours_between first latest)
  | _ -> `Null

let first_ts_origin_json = function
  | History_head None ->
    `Assoc [ ("segment", `String "current"); ("rotation", `Null) ]
  | History_head (Some rotation) ->
    `Assoc [ ("segment", `String "rotated"); ("rotation", `Int rotation) ]
  | History_scan_exhausted rotation ->
    `Assoc
      [ ("segment", `String "scan_exhausted")
      ; ( "rotation"
        , Option.fold ~none:`Null ~some:(fun value -> `Int value) rotation )
      ]
  | No_turn_row_in_history ->
    `Assoc [ ("segment", `String "none"); ("rotation", `Null) ]

let latest_age_hours_json ~now stat =
  match stat.latest_ts with
  | Some latest -> `Float (latest_age_hours ~now latest)
  | None -> `Null

let has_persistent_turn_span_for ~required_span_hours ~now stat =
  Float.is_finite required_span_hours
  && required_span_hours > 0.0
  &&
  match stat.first_ts, stat.latest_ts with
  | Some first, Some latest ->
    first <= latest
    && latest <= now
    && hours_between first latest >= required_span_hours
    && latest_age_hours ~now latest <= recent_turn_max_age_hours
  | Some _, None | None, Some _ | None, None -> false

let has_persistent_turn_span ~now stat =
  has_persistent_turn_span_for
    ~required_span_hours:persistent_turn_window_hours
    ~now
    stat
;;

(* What the reader could establish about a required span. The predicates above
   answer one question - was the span proven - and answer it correctly: an
   unread history proves nothing. They cannot answer the second question a
   report needs, which is whether [false] came from the keeper or from the
   reader. A head scan that ran out of budget leaves the earliest turn row
   unseen, so the span is unknown rather than short, and a report holding only
   the boolean has to file that keeper under "did not do it". *)
type span_reading =
  | Span_met
  | Span_not_met
  | Span_undetermined

let persistent_turn_span_reading ~required_span_hours ~now stat =
  match stat.first_ts_origin with
  | History_scan_exhausted _ -> Span_undetermined
  | History_head _ | No_turn_row_in_history ->
    if has_persistent_turn_span_for ~required_span_hours ~now stat
    then Span_met
    else Span_not_met

let span_reading_to_string = function
  | Span_met -> "met"
  | Span_not_met -> "not_met"
  | Span_undetermined -> "undetermined"

let turn_span_evidence_json ~now keeper_name stat =
  `Assoc [
    ("keeper", `String keeper_name);
    ("recent_interaction_count", `Int stat.recent_interaction_count);
    ("first_ts_origin", first_ts_origin_json stat.first_ts_origin);
    ("segments_observed", `Int stat.segments_observed);
    ("first_ts_unix", unix_opt_to_json stat.first_ts);
    ("first_ts_iso", unix_opt_to_iso_json stat.first_ts);
    ("latest_ts_unix", unix_opt_to_json stat.latest_ts);
    ("latest_ts_iso", unix_opt_to_iso_json stat.latest_ts);
    ("span_hours", turn_span_hours_json stat);
    ("latest_age_hours", latest_age_hours_json ~now stat);
    ( "persistence_24h",
      `String
        (span_reading_to_string
           (persistent_turn_span_reading
              ~required_span_hours:persistent_turn_window_hours
              ~now
              stat)) );
  ]
