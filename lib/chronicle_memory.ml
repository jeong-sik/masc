(** Chronicle_memory -- inject git chronicle candidates into episodic memory. *)

let take n xs =
  let rec loop remaining acc = function
    | [] -> List.rev acc
    | _ when remaining <= 0 -> List.rev acc
    | x :: rest -> loop (remaining - 1) (x :: acc) rest
  in
  loop n [] xs

let sanitize_id raw =
  let buf = Buffer.create (String.length raw) in
  String.iter
    (function
      | 'a' .. 'z' as c -> Buffer.add_char buf c
      | 'A' .. 'Z' as c -> Buffer.add_char buf c
      | '0' .. '9' as c -> Buffer.add_char buf c
      | '-' -> Buffer.add_char buf '-'
      | '_' -> Buffer.add_char buf '_'
      | '#' -> Buffer.add_string buf "issue-"
      | _ -> Buffer.add_char buf '-')
    raw;
  let value = Buffer.contents buf |> String.trim in
  if String.equal value "" then "unknown" else value

let short_sha sha =
  let len = min 12 (String.length sha) in
  String.sub sha 0 len

let episode_id (epoch : Chronicle_ingest.candidate_epoch) =
  Printf.sprintf "git-chronicle-%s-%s"
    (sanitize_id epoch.id)
    (short_sha epoch.end_commit)

let csv values = String.concat "," values

let commit_label count =
  if count = 1 then "1 commit" else Printf.sprintf "%d commits" count

let summary_of_candidate (epoch : Chronicle_ingest.candidate_epoch) =
  let file_preview =
    match take 5 epoch.file_paths with
    | [] -> ""
    | files -> Printf.sprintf "; files: %s" (String.concat ", " files)
  in
  Printf.sprintf "Git chronicle %s: %s (%s%s)"
    epoch.id epoch.label (commit_label epoch.commit_count) file_preview

let learnings_of_candidate (epoch : Chronicle_ingest.candidate_epoch) =
  [ "git_chronicle_epoch: " ^ epoch.id
  ; "commit_count: " ^ string_of_int epoch.commit_count
  ; Printf.sprintf "commit_range: %s..%s"
      (short_sha epoch.start_commit)
      (short_sha epoch.end_commit)
  ]
  @ List.map (fun goal_id -> "goal_id: " ^ goal_id) epoch.goal_ids

let salience_of_candidate (epoch : Chronicle_ingest.candidate_epoch) =
  let commit_signal =
    min 0.2 (float_of_int epoch.commit_count *. 0.02)
  in
  let goal_signal =
    min 0.15 (float_of_int (List.length epoch.goal_ids) *. 0.05)
  in
  min 0.95 (0.55 +. commit_signal +. goal_signal)

let utc_midnight_of_yyyy_mm_dd raw =
  try
    Scanf.sscanf raw "%04d-%02d-%02d" (fun year month day ->
        let tm =
          {
            Unix.tm_sec = 0;
            tm_min = 0;
            tm_hour = 0;
            tm_mday = day;
            tm_mon = month - 1;
            tm_year = year - 1900;
            tm_wday = 0;
            tm_yday = 0;
            tm_isdst = false;
          }
        in
        let local_epoch, _ = Unix.mktime tm in
        let utc_as_local, _ = Unix.mktime (Unix.gmtime local_epoch) in
        let tz_offset = local_epoch -. utc_as_local in
        Some (local_epoch +. tz_offset))
  with Scanf.Scan_failure _ | Failure _ | End_of_file | Invalid_argument _ ->
    None

let default_timestamp_of_candidate epoch =
  Option.value
    (utc_midnight_of_yyyy_mm_dd epoch.Chronicle_ingest.end_date)
    ~default:(Time_compat.now ())

let episode_of_candidate ?timestamp ~keeper_name
    (epoch : Chronicle_ingest.candidate_epoch) : Agent_sdk.Memory.episode =
  let summary = summary_of_candidate epoch in
  let learnings = learnings_of_candidate epoch in
  let context =
    [ "source", `String "git_chronicle"
    ; "epoch_id", `String epoch.id
    ; "start_commit", `String epoch.start_commit
    ; "end_commit", `String epoch.end_commit
    ; "start_date", `String epoch.start_date
    ; "end_date", `String epoch.end_date
    ; "commit_count", `String (string_of_int epoch.commit_count)
    ; "goal_ids", `String (csv epoch.goal_ids)
    ; "file_paths", `String (csv epoch.file_paths)
    ]
  in
  { id = episode_id epoch
  ; timestamp = Option.value timestamp ~default:(default_timestamp_of_candidate epoch)
  ; participants = [ keeper_name ]
  ; action = summary
  ; outcome = Agent_sdk.Memory.Neutral
  ; salience = salience_of_candidate epoch
  ; metadata =
      [ "event_type", `String "git_chronicle"
      ; "institution_summary", `String summary
      ; "institution_outcome", `String "partial"
      ; "learnings", `List (List.map (fun item -> `String item) learnings)
      ; "context", `Assoc context
      ; "source", `String "git_chronicle"
      ; "goal_ids", `List (List.map (fun item -> `String item) epoch.goal_ids)
      ; "file_paths", `List (List.map (fun item -> `String item) epoch.file_paths)
      ]
  }

let store_candidate_epoch ?timestamp ~memory ~keeper_name epoch =
  Agent_sdk.Memory.store_episode memory
    (episode_of_candidate ?timestamp ~keeper_name epoch)

let store_candidate_epochs ?timestamp ~memory ~keeper_name epochs =
  List.iter (store_candidate_epoch ?timestamp ~memory ~keeper_name) epochs;
  List.length epochs
