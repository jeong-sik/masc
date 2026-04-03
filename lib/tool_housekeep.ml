(** Housekeeping tools for keeper agents.

    Gives keepers the ability to observe and maintain their own world (.masc/).
    The keeper decides what to clean; these tools provide the means. *)


let masc_dir config = Room_utils.masc_dir config

(* ── Scan ─────────────────────────────────────────────── *)

type file_entry = {
  path : string;
  size_bytes : int;
  age_days : float;
  category : string;
}

let classify_path path =
  let base = Filename.basename path in
  let dir = Filename.basename (Filename.dirname path) in
  if Filename.check_suffix base ".json" && dir = "keepers" then "keeper_meta"
  else if Filename.check_suffix base ".metrics.jsonl" then "keeper_metrics_single_file"
  else if Filename.check_suffix base ".memory.jsonl" then "keeper_memory"
  else if Filename.check_suffix base ".feedback.jsonl" then "keeper_feedback"
  else if Filename.check_suffix base ".jsonl" && dir = "events" then "events"
  else if Filename.check_suffix base ".jsonl" then "jsonl_data"
  else if dir = "metrics" || dir = "audit" || dir = "telemetry" then "dated_split"
  else "other"

let scan_dir_recursive base_path =
  let now = Unix.gettimeofday () in
  let entries = ref [] in
  let rec walk dir =
    if Sys.file_exists dir && Sys.is_directory dir then begin
      let children =
        try Array.to_list (Sys.readdir dir)
        with Sys_error _ -> []
      in
      List.iter (fun name ->
        let full = Filename.concat dir name in
        if Sys.is_directory full then
          walk full
        else begin
          match (try Some (Unix.stat full) with Unix.Unix_error _ -> None) with
          | None -> ()
          | Some st ->
            let age_days = (now -. st.Unix.st_mtime) /. 86400.0 in
            entries := {
              path = full;
              size_bytes = st.Unix.st_size;
              age_days;
              category = classify_path full;
            } :: !entries
        end
      ) children
    end
  in
  walk base_path;
  List.rev !entries

let entry_to_json e =
  `Assoc [
    ("path", `String e.path);
    ("size_bytes", `Int e.size_bytes);
    ("age_days", `Float (Float.round e.age_days *. 10.0 /. 10.0));
    ("category", `String e.category);
  ]

let handle_housekeep_scan config args =
  let category_filter =
    match Yojson.Safe.Util.member "category" args with
    | `String s when s <> "" -> Some s
    | _ -> None
  in
  let min_age_days =
    match Yojson.Safe.Util.member "min_age_days" args with
    | `Int n -> float_of_int n
    | `Float f -> f
    | _ -> 0.0
  in
  let base = masc_dir config in
  let entries = scan_dir_recursive base in
  let filtered = entries
    |> List.filter (fun e ->
      e.age_days >= min_age_days
      && (match category_filter with
          | None -> true
          | Some cat -> e.category = cat))
  in
  let total_bytes = List.fold_left (fun acc e -> acc + e.size_bytes) 0 filtered in
  let json = `Assoc [
    ("total_files", `Int (List.length filtered));
    ("total_bytes", `Int total_bytes);
    ("files", `List (List.map entry_to_json filtered));
  ] in
  (true, Yojson.Safe.to_string json)

(* ── Delete ───────────────────────────────────────────── *)

let housekeep_log_path config =
  Filename.concat (masc_dir config) "housekeep.log"

let log_deletion config ~path ~reason =
  let ts = Types.now_iso () in
  let line = Printf.sprintf "[%s] DELETED %s reason=%s\n" ts path reason in
  let log_path = housekeep_log_path config in
  Fs_compat.append_file log_path line

let handle_housekeep_delete config args =
  let path =
    match Yojson.Safe.Util.member "path" args with
    | `String s -> s
    | _ -> ""
  in
  let reason =
    match Yojson.Safe.Util.member "reason" args with
    | `String s -> s
    | _ -> "unspecified"
  in
  if path = "" then
    (false, "path is required")
  else
    let base = masc_dir config in
    (* Safety: only allow deletion under .masc/ *)
    if not (String.length path > String.length base
            && String.sub path 0 (String.length base) = base) then
      (false, Printf.sprintf "refused: path %s is not under %s" path base)
    else if not (Sys.file_exists path) then
      (false, Printf.sprintf "not found: %s" path)
    else if Sys.is_directory path then
      (false, Printf.sprintf "refused: %s is a directory (use prune for dated stores)" path)
    else begin
      let size =
        match (try Some (Unix.stat path) with Unix.Unix_error _ -> None) with
        | Some st -> st.Unix.st_size
        | None -> 0
      in
      (try Sys.remove path with Sys_error _ -> ());
      log_deletion config ~path ~reason;
      let json = `Assoc [
        ("deleted", `String path);
        ("size_bytes", `Int size);
        ("reason", `String reason);
      ] in
      (true, Yojson.Safe.to_string json)
    end

(* ── Prune ────────────────────────────────────────────── *)

let handle_housekeep_prune config args =
  let store_name =
    match Yojson.Safe.Util.member "store" args with
    | `String s -> s
    | _ -> ""
  in
  let days =
    match Yojson.Safe.Util.member "days" args with
    | `Int n -> n
    | _ -> 30
  in
  if store_name = "" then
    (false, "store is required (audit, telemetry, or keeper:<name>)")
  else
    let base = masc_dir config in
    let store_dir =
      if store_name = "audit" then Filename.concat base "audit"
      else if store_name = "telemetry" then Filename.concat base "telemetry"
      else if String.length store_name > 7
              && String.sub store_name 0 7 = "keeper:" then
        let keeper_name = String.sub store_name 7 (String.length store_name - 7) in
        Filename.concat (Filename.concat base "keepers") (keeper_name ^ "/metrics")
      else ""
    in
    if store_dir = "" then
      (false, Printf.sprintf "unknown store: %s" store_name)
    else if not (Sys.file_exists store_dir) then
      (true, Printf.sprintf "store %s does not exist yet (nothing to prune)" store_name)
    else begin
      let store = Dated_jsonl.create ~base_dir:store_dir () in
      let deleted = Dated_jsonl.prune store ~days in
      log_deletion config
        ~path:store_dir
        ~reason:(Printf.sprintf "prune days=%d deleted=%d" days deleted);
      let json = `Assoc [
        ("store", `String store_name);
        ("store_dir", `String store_dir);
        ("days", `Int days);
        ("files_deleted", `Int deleted);
      ] in
      (true, Yojson.Safe.to_string json)
    end

(* Dispatch removed: housekeep tools purged (zero callers). *)
