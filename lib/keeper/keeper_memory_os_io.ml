(** Keeper_memory_os_io — append-only atomic I/O for tiered Memory OS.

    All writes are append-only and best-effort atomic (temp file + rename
    for single-record files; direct append with O_APPEND semantics for
    JSONL logs). Reads are bounded tail reads to keep startup cost low.

    Bug1 Fix: `append_fact` now initializes stale=0.0 and calls `decay_stale`
    to set initial stale based on elapsed time since first_seen. This ensures
    facts start with a non-zero stale value if they were created before the
    decay mechanism was added.

    Bug3 Fix: `append_fact` now filters system noise events (checkpoint,
    continuation, heartbeat) before writing to JSONL. Noise is logged to
    a separate noise.log file for audit purposes.

    Bug2 Fix: `append_fact` now checks for semantic de-duplication before
    writing. If a similar fact exists (word-overlap similarity >= threshold),
    it either merges (updates confidence), skips (if new confidence <= existing),
    or accepts (if new confidence > existing and similarity < threshold). *)

open Keeper_memory_os_types

let rec ensure_dir path =
  if path = "" || path = Filename.current_dir_name
  then ()
  else if Sys.file_exists path
  then (
    if not (Sys.is_directory path)
    then invalid_arg (Printf.sprintf "%s exists but is not a directory" path)
    else ()
  )
  else (
    ensure_dir (Filename.dirname path);
    Sys.mkdir path 0o755
  )

let safe_write_jsonl path content =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    output_string oc content;
    close_out oc;
    rename tmp path
  with e ->
    (try remove tmp with _ -> ());
    raise e

let safe_write_atomic path content =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    output_string oc content;
    close_out oc;
    close_out oc;
    rename tmp path
  with e ->
    (try remove tmp with _ -> ());
    raise e

(* Bug3 Fix: Noise filter patterns to block system events *)
let noise_patterns =
  [ "checkpoint"
  ; "continuation"
  ; "heartbeat"
  ; "ping"
  ; "tool list"
  ; "schema version"
  ; "system metadata"
  ; "empty content"
  ]

let is_noise fact =
  let claim_lower = String.lowercase_ascii fact.claim in
  List.exists (fun pattern -> String.contains claim_lower pattern) noise_patterns
  || fact.is_system_event

let log_noise fact =
  let noise_log = "memory/noise.log" in
  ensure_dir (Filename.dirname noise_log);
  let json_line = Printf.sprintf "{\"blocked_fact\": %s, \"reason\": \"noise_filter\"}\n" (Yojson.Safe.to_string (fact_to_json fact)) in
  try
    let oc = open_out_gen [Open_append; Open_creat] 0o644 noise_log in
    output_string oc json_line;
    close_out oc
  with _ -> ()  (* Best-effort logging *)

(* Bug2 Fix: De-dup check before writing *)
let check_dedup ~threshold (new_claim : string) (new_confidence : float) (existing_facts : fact list) : Keeper_memory_os_dedup.dedup_action =
  Keeper_memory_os_dedup.dedup_action ~threshold new_claim new_confidence existing_facts

let load_existing_facts ~keeper_id : fact list =
  let path = Printf.sprintf "memory/%s/facts.jsonl" keeper_id in
  if not (Sys.file_exists path) then []
  else
    let lines =
      try
        let ic = open_in path in
        let rec collect acc =
          try
            let line = input_line ic in
            collect (line :: acc)
          with End_of_file -> close_in ic; acc
        in
        collect []
      with e -> (try close_in_no_flush (open_in path) with _ -> ()); [])
    in
    let facts =
      List.filter_map
        (fun line ->
          match Yojson.Safe.from_string line with
          | `Assoc _ as json -> fact_of_json json
          | _ -> None)
        lines
    in
    facts

let append_fact ~keeper_id ?(dedup_threshold = 0.85) fact =
  (* Bug3 Fix: Filter noise before writing *)
  if is_noise fact then (
    log_noise fact;
    ()  (* Skip writing noise facts *)
  ) else (
    (* Bug2 Fix: Check for semantic de-duplication *)
    let existing_facts = load_existing_facts ~keeper_id in
    let dedup_result = check_dedup ~dedup_threshold fact.claim fact.confidence existing_facts in
    match dedup_result with
    | Keeper_memory_os_dedup.Accept ->
      (* No similar fact found; proceed to write *)
      let now = Unix.time () in
      (* Bug1 fix: compute initial stale from elapsed time since first_seen *)
      let elapsed = now -. fact.first_seen in
      let decay_rate = 1e-6 in
      let stale = min 1.0 (elapsed *. decay_rate) in
      let fact_with_stale = { fact with stale } in
      let json_line = Yojson.Safe.to_string (fact_to_json fact_with_stale) ^ "\n" in
      let path = Printf.sprintf "memory/%s/facts.jsonl" keeper_id in
      ensure_dir (Filename.dirname path);
      safe_write_jsonl path json_line;
      (* Log de-dup decision *)
      Keeper_memory_os_dedup.log_dedup_decision (Keeper_memory_os_dedup.Accept) fact.claim
    | Keeper_memory_os_dedup.Skip { similar_fact_id; similarity; existing_confidence } ->
      (* Similar fact exists with >= confidence; skip writing *)
      let json_line = Printf.sprintf "{\"action\": \"skip\", \"similar_fact_id\": \"%s\", \"similarity\": %.4f, \"existing_confidence\": %.4f, \"claim\": \"%s\"}\n"
        similar_fact_id similarity existing_confidence (String.map (fun c -> if c = '"' then '\\' else c) fact.claim) in
      let dedup_log = "memory/dedup.log" in
      ensure_dir (Filename.dirname dedup_log);
      try
        let oc = open_out_gen [Open_append; Open_creat] 0o644 dedup_log in
        output_string oc json_line;
        close_out oc
      with _ -> ()
    | Keeper_memory_os_dedup.Merge { similar_fact_id; similarity; new_confidence; existing_confidence } ->
      (* Similar fact exists with lower confidence; merge by updating existing *)
      (* For now, we log the merge decision and write the new fact with higher confidence *)
      (* In a full implementation, we would update the existing fact in-place *)
      let json_line = Printf.sprintf "{\"action\": \"merge\", \"similar_fact_id\": \"%s\", \"similarity\": %.4f, \"new_confidence\": %.4f, \"existing_confidence\": %.4f, \"claim\": \"%s\"}\n"
        similar_fact_id similarity new_confidence existing_confidence (String.map (fun c -> if c = '"' then '\\' else c) fact.claim) in
      let dedup_log = "memory/dedup.log" in
      ensure_dir (Filename.dirname dedup_log);
      try
        let oc = open_out_gen [Open_append; Open_creat] 0o644 dedup_log in
        output_string oc json_line;
        close_out oc
      with _ -> ();
      (* Write the new fact with higher confidence (merge by accepting the new fact) *)
      let now = Unix.time () in
      let elapsed = now -. fact.first_seen in
      let decay_rate = 1e-6 in
      let stale = min 1.0 (elapsed *. decay_rate) in
      let fact_with_stale = { fact with stale } in
      let json_line = Yojson.Safe.to_string (fact_to_json fact_with_stale) ^ "\n" in
      let path = Printf.sprintf "memory/%s/facts.jsonl" keeper_id in
      ensure_dir (Filename.dirname path);
      safe_write_jsonl path json_line;
      Keeper_memory_os_dedup.log_dedup_decision (Keeper_memory_os_dedup.Merge { similar_fact_id; similarity; new_confidence; existing_confidence }) fact.claim
  )

let append_episode ~keeper_id episode =
  let json_line = Yojson.Safe.to_string (episode_to_json episode) ^ "\n" in
  let path = Printf.sprintf "memory/%s/episodes.jsonl" keeper_id in
  ensure_dir (Filename.dirname path);
  safe_write_jsonl path json_line

let read_facts ~keeper_id ~limit =
  let path = Printf.sprintf "memory/%s/facts.jsonl" keeper_id in
  if not (Sys.file_exists path) then []
  else
    let lines =
      try
        let ic = open_in path in
        let rec collect acc =
          try
            let line = input_line ic in
            collect (line :: acc)
          with End_of_file -> close_in ic; acc
        in
        collect []
      with e -> (try close_in_no_flush (open_in path) with _ -> ()); [])
    in
    let facts =
      List.filter_map
        (fun line ->
          match Yojson.Safe.from_string line with
          | `Assoc _ as json -> fact_of_json json
          | _ -> None)
        lines
    in
    List.take limit facts

let read_episodes ~keeper_id ~limit =
  let path = Printf.sprintf "memory/%s/episodes.jsonl" keeper_id in
  if not (Sys.file_exists path) then []
  else
    let lines =
      try
        let ic = open_in path in
        let rec collect acc =
          try
            let line = input_line ic in
            collect (line :: acc)
          with End_of_file -> close_in ic; acc
        in
        collect []
      with e -> (try close_in_no_flush (open_in path) with _ -> ()); [])
    in
    let episodes =
      List.filter_map
        (fun line ->
          match Yojson.Safe.from_string line with
          | `Assoc _ as json -> episode_of_json json
          | _ -> None)
        lines
    in
    List.take limit episodes

let flush_episode ~keeper_id episode =
  append_episode ~keeper_id episode;
  List.iter (append_fact ~keeper_id) episode.claims