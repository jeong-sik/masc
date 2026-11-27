(** Audit Log Writer for MASC

    Writes audit events to .masc/audit/YYYY-MM/DD.jsonl for security monitoring.
    JSONL format for grep-ability and stream processing.

    Security basis:
    - Open Challenges in MAS Security (arxiv:2505.02077v1)
    - Immutable audit trails for post-incident analysis

    @since 0.6.0 - MASC Social v4 Tier 1
*)

module StringMap = Set_util.StringMap

(** {1 Types} *)

type outcome =
  | Success [@tla.symbol "success"]
  | Failure of string [@tla.symbol "failure"]
[@@deriving tla]

let outcome_tla_symbol = to_tla_symbol

type gate_audit_decision =
  | Gate_allow [@tla.symbol "gate_allow"]
  | Gate_require_confirmation [@tla.symbol "gate_require_confirmation"]
  | Gate_deny [@tla.symbol "gate_deny"]
  | Gate_confirm [@tla.symbol "gate_confirm"]
  | Gate_expired [@tla.symbol "gate_expired"]
  | Gate_unauthorized [@tla.symbol "gate_unauthorized"]
  | Gate_other of string [@tla.symbol "gate_other"]
[@@deriving tla]

type action =
  | ClaimTask [@tla.symbol "claim_task"]
  | StartTask [@tla.symbol "start_task"]
  | DoneTask [@tla.symbol "done_task"]
  | CancelTask [@tla.symbol "cancel_task"]
  | ReleaseTask [@tla.symbol "release_task"]
  | Broadcast [@tla.symbol "broadcast"]
  | Suspend [@tla.symbol "suspend"]
  | ToolCall of string [@tla.symbol "tool_call"]
  | AuthSuccess [@tla.symbol "auth_success"]
  | AuthFailure [@tla.symbol "auth_failure"]
  | CircuitOpen [@tla.symbol "circuit_open"]
  | CircuitClose [@tla.symbol "circuit_close"]
  | SearchRefinement [@tla.symbol "search_refinement"]
  | GateDecision of gate_audit_decision [@tla.symbol "gate_decision"]
  | RuntimeConfigWrite [@tla.symbol "runtime_config_write"]
  | Custom of string [@tla.symbol "custom"]
  | Unknown of string [@tla.symbol "unknown"]
[@@deriving tla]

type audit_entry = {
  timestamp: float;
  agent_id: string;
  action: action;
  details: Yojson.Safe.t;
  outcome: outcome;
  trace_id: string option;
}

let preview ?(max_len = 200) (value : string) =
  (* UTF-8-safe truncation: byte-based String.sub split multi-byte chars in
     audit/*.jsonl. See Issue #7690. Use [max_bytes:(max_len + 3)] so that
     output length cap matches the original (prefix + suffix). *)
  String_util.utf8_safe ~max_bytes:(max_len + 3) ~suffix:"..." value
  |> String_util.to_string

(* [audit_summary] renders raw detail fields, so it cannot reuse [preview]'s
   "..." suffix, but it needs the same character-boundary cut. *)
let audit_summary_field_max_bytes = 80

let audit_summary_field value =
  String_util.utf8_prefix ~max_bytes:audit_summary_field_max_bytes value

(** {1 Serialization} *)

let gate_audit_decision_to_string = function
  | Gate_allow -> "allow"
  | Gate_require_confirmation -> "require_confirmation"
  | Gate_deny -> "deny"
  | Gate_confirm -> "confirm"
  | Gate_expired -> "expired"
  | Gate_unauthorized -> "unauthorized"
  | Gate_other value -> value

let gate_audit_decision_of_string = function
  | "allow" -> Gate_allow
  | "require_confirmation" -> Gate_require_confirmation
  | "deny" -> Gate_deny
  | "confirm" -> Gate_confirm
  | "expired" -> Gate_expired
  | "unauthorized" -> Gate_unauthorized
  | value -> Gate_other value

let action_to_string = function
  | ClaimTask -> "claim_task"
  | StartTask -> "start_task"
  | DoneTask -> "done_task"
  | CancelTask -> "cancel_task"
  | ReleaseTask -> "release_task"
  | Broadcast -> "broadcast"
  | Suspend -> "suspend"
  | ToolCall name -> "tool_call:" ^ name
  | AuthSuccess -> "auth_success"
  | AuthFailure -> "auth_failure"
  | CircuitOpen -> "circuit_open"
  | CircuitClose -> "circuit_close"
  | SearchRefinement -> "search_refinement"
  | GateDecision decision -> "gate_decision:" ^ gate_audit_decision_to_string decision
  | RuntimeConfigWrite -> "runtime_config_write"
  | Custom name -> "custom:" ^ name
  | Unknown raw -> raw

let unknown_action raw =
  (* [Unknown] is the forward-compatible unknown-action variant for audit-log
     wire strings. Keep this path named so the parser does not look like a
     silent coercion to a normal concrete action. *)
  Unknown raw

let string_to_action s =
  (* Split on first ':' to separate tag from payload for parameterized
     variants.  Simple action names without ':' match directly.  This
     replaces the old prefix+magic-length approach which was fragile:
     magic numbers drifted from tag lengths, and a fixed-length prefix
     could not account for variable-length payloads. *)
  match String.index_opt s ':' with
  | Some colon_pos ->
    let tag = String.sub s 0 colon_pos in
    let payload = String.sub s (colon_pos + 1) (String.length s - colon_pos - 1) in
    (match tag with
     | "tool_call" -> ToolCall payload
     | "gate_decision" -> GateDecision (gate_audit_decision_of_string payload)
     | "custom" -> Custom payload
     | _ -> unknown_action s)
  | None ->
    (match s with
     | "claim_task" -> ClaimTask
     | "start_task" -> StartTask
     | "done_task" -> DoneTask
     | "cancel_task" -> CancelTask
     | "release_task" -> ReleaseTask
     | "broadcast" -> Broadcast
     | "suspend" -> Suspend
     | "auth_success" -> AuthSuccess
     | "auth_failure" -> AuthFailure
     | "circuit_open" -> CircuitOpen
     | "circuit_close" -> CircuitClose
     | "search_refinement" -> SearchRefinement
     | "runtime_config_write" -> RuntimeConfigWrite
     | _ -> unknown_action s)

let outcome_to_json = function
  | Success -> `Assoc [("status", `String (outcome_tla_symbol Success))]
  | Failure reason -> `Assoc [
      ("status", `String (outcome_tla_symbol (Failure reason)));
      ("reason", `String reason);
    ]

let entry_to_json (e : audit_entry) : Yojson.Safe.t =
  let base = [
    ("timestamp", `Float e.timestamp);
    ("agent_id", `String e.agent_id);
    ("action", `String (action_to_string e.action));
    ("details", e.details);
    ("outcome", outcome_to_json e.outcome);
  ] in
  let with_trace = match e.trace_id with
    | Some tid -> base @ [("trace_id", `String tid)]
    | None -> base
  in
  `Assoc with_trace

(** Parse a JSON object back into an audit_entry.
    Returns Error with reason on parse failure (never silently drops). *)
let entry_of_json_r (json : Yojson.Safe.t) : (audit_entry, string) result =
  try
    let timestamp = Json_util.get_float json "timestamp" in
    let agent_id = Json_util.get_string json "agent_id" in
    let action_raw = Json_util.get_string json "action" in
    let details =
      match Safe_ops.json_member_opt "details" json with
      | Some v -> v
      | None -> `Null
    in
    let outcome =
      match Json_util.get_object json "outcome" with
      | Some o ->
        (match Json_util.get_string o "status" with
         | Some status when String.equal status (outcome_tla_symbol Success) ->
           Success
         | Some _ | None ->
           let reason = Safe_ops.json_string ~default:"unknown" "reason" o in
           Failure reason)
      | None -> Failure "missing outcome"
    in
    let trace_id = Safe_ops.json_string_opt "trace_id" json in
    match timestamp, agent_id, action_raw with
    | Some timestamp, Some agent_id, Some action_raw ->
      let action = string_to_action action_raw in
      Ok { timestamp; agent_id; action; details; outcome; trace_id }
    | _ -> Error "missing required fields (timestamp, agent_id, action)"
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    (* Redact details field to prevent sensitive content leaking into logs *)
    let redacted = match json with
      | `Assoc fields ->
        let safe_fields = List.filter_map (fun (k, v) ->
          if k = "details" then Some (k, `String "<redacted>")
          else Some (k, v)
        ) fields in
        `Assoc safe_fields
      | _ -> `String "<non-object>"
    in
    let snippet = preview (Yojson.Safe.to_string redacted) in
    Error (Printf.sprintf "%s | json: %s" (Printexc.to_string exn) snippet)

(** {1 File Operations} *)

type config = Workspace_utils.config

(** Date-split store: [.masc/audit/YYYY-MM/DD.jsonl].
    Cached per base_dir so all callers share the same Eio.Mutex.

    The cache itself is protected by [audit_store_cache_mu] so that
    two concurrent [get_audit_store] calls for the same base dir
    cannot install two [Dated_jsonl.t] records with different inner
    [Eio.Mutex] instances — otherwise file I/O to the same
    [YYYY-MM/DD.jsonl] path would serialise through two different
    mutexes and racing appends could interleave on disk.  Under the
    current single-domain Eio with a non-yielding [Dated_jsonl.open_store]
    this race does not fire today, but the fix is cheap and removes a
    fragile implicit invariant. *)
let audit_store_cache : Dated_jsonl.t StringMap.t ref = ref StringMap.empty
let audit_store_cache_mu = Eio.Mutex.create ()

(* The directory this store occupies under [.masc]. Exposed so readers of the
   same store name it from here instead of spelling the literal. *)
let store_dirname = Dated_jsonl.Store.Root.(relative_path Audit)

let get_audit_store (config : config) : Dated_jsonl.t =
  let location =
    Dated_jsonl.Store.at
      (Workspace_utils.dated_store_root config)
      Dated_jsonl.Store.Root.Audit
  in
  let base = Dated_jsonl.Store.dir location in
  Eio_guard.with_mutex audit_store_cache_mu (fun () ->
    match StringMap.find_opt base !audit_store_cache with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.open_store location in
      audit_store_cache := StringMap.add base store !audit_store_cache;
      store)

(** How many individual corrupt-entry failures {!collect_entries} reports
    before it switches to a suppressed count in the summary. *)
let max_logged_errors = 5

(* Takes decode results rather than rows. [read_entries] decodes during the
   read so the parsed trees are not all held at once, and the reader calls its
   projection newest-first — so the rate-limited logging below must stay out of
   the projection, or which five failures get reported would flip. Folding over
   the returned (chronological) list keeps the reported set and the [#N]
   numbering identical to reading the whole window first. *)
let collect_entries (decoded : (audit_entry, string) result list) :
    audit_entry list =
  let ok_rev, err_count =
    List.fold_left
      (fun (ok, errc) -> function
        | Ok entry -> (entry :: ok, errc)
        | Error reason ->
            let errc = errc + 1 in
            if errc <= max_logged_errors then
              Log.Misc.error "audit_log: corrupt entry (#%d): %s" errc reason;
            (ok, errc))
      ([], 0)
      decoded
  in
  if err_count > 0 then
    Log.Misc.error "audit_log: %d/%d entries failed to parse (possible corruption)%s"
      err_count (List.length decoded)
      (if err_count > max_logged_errors
       then Printf.sprintf " (%d more suppressed)" (err_count - max_logged_errors)
       else "");
  List.rev ok_rev

(* Stat-validated incremental per-day-file decoded cache.
   Every read validates [(dev, ino, size, mtime, ctime, perm, uid, gid)] via
   [Unix.stat] so external appends, replacements, truncations, and deletions are
   observed immediately (zero TTL staleness). Only settled files
   ([now -. mtime >= 0.05 && now -. ctime >= 0.05], no [Float.abs] so future
   timestamps never cache) are inserted into [day_cache]; unsettled files are
   decoded freshly without caching so same-tick same-size overwrites can never
   be served stale. Appends verify both prefix and boundary byte samples before
   seeking to [parsed_offset] so same-inode [O_TRUNC] + larger rewrites trigger
   a clean full re-parse. Files above [max_cached_day_file_bytes] fall back to
   [Dated_jsonl]'s chunked backward scan without caching. *)
let max_cached_day_file_bytes = 4 * 1024 * 1024
let max_cached_day_files = 64
let max_cached_total_bytes = 32 * 1024 * 1024
let stat_settle_window_sec = 0.05
let sample_window_bytes = 64

type cached_day_file = {
  dev : int;
  ino : int;
  size : int;
  mtime : float;
  ctime : float;
  perm : int;
  uid : int;
  gid : int;
  parsed_offset : int;
  prefix_sample : string;
  boundary_sample : string;
  (* Complete '\n'-terminated JSON-parseable rows, newest first. *)
  complete_rows_rev : (audit_entry, string) result list;
  (* Count of [Ok] entries in [complete_rows_rev] and whether any [Error] exists. *)
  complete_valid_count : int;
  complete_has_corrupt : bool;
  (* Unterminated trailing JSON-parseable row past [parsed_offset], if any. *)
  trailing_row : (audit_entry, string) result option;
  mutable last_used : int;
}

type day_file_load =
  | Day_missing
  | Day_fallback
  | Day_uncached of cached_day_file
  | Day_loaded of cached_day_file

let day_cache_mu = Stdlib.Mutex.create ()
let day_cache : (string, cached_day_file) Hashtbl.t = Hashtbl.create 32
let day_cache_bytes = ref 0
let day_cache_clock = ref 0

let trim_whitespace = function
  | ' ' | '\012' | '\n' | '\r' | '\t' -> true
  | _ -> false

let rec substring_has_content s index stop =
  index < stop
  && (not (trim_whitespace (String.unsafe_get s index))
      || substring_has_content s (index + 1) stop)

let parse_audit_line_opt line =
  match Yojson.Safe.from_string line with
  | json -> Some (entry_of_json_r json)
  | exception Yojson.Json_error _ -> None

let parse_chunk_into ~base_offset ~init_rev ~init_valid_count ~init_has_corrupt bytes =
  let len = String.length bytes in
  let rec loop pos parsed_offset acc valid_count has_corrupt =
    if pos >= len then (parsed_offset, acc, valid_count, has_corrupt, None)
    else
      match String.index_from_opt bytes pos '\n' with
      | Some nl ->
        let next_parsed = base_offset + nl + 1 in
        let acc, valid_count, has_corrupt =
          if substring_has_content bytes pos nl then
            match parse_audit_line_opt (String.sub bytes pos (nl - pos)) with
            | Some (Ok _ as row) -> (row :: acc, valid_count + 1, has_corrupt)
            | Some (Error _ as row) -> (row :: acc, valid_count, true)
            | None -> (acc, valid_count, has_corrupt)
          else (acc, valid_count, has_corrupt)
        in
        loop (nl + 1) next_parsed acc valid_count has_corrupt
      | None ->
        let trailing =
          if substring_has_content bytes pos len then
            parse_audit_line_opt (String.sub bytes pos (len - pos))
          else None
        in
        (parsed_offset, acc, valid_count, has_corrupt, trailing)
  in
  loop 0 base_offset init_rev init_valid_count init_has_corrupt

let read_fd_range fd ~from ~len =
  if len <= 0 then ""
  else begin
    ignore (Unix.lseek fd from Unix.SEEK_SET : int);
    let buf = Bytes.create len in
    let rec loop filled =
      if filled >= len then Bytes.unsafe_to_string buf
      else
        match Unix.read fd buf filled (len - filled) with
        | 0 -> Bytes.sub_string buf 0 filled
        | n -> loop (filled + n)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop filled
    in
    loop 0
  end

let day_cache_evict_unlocked () =
  while
    Hashtbl.length day_cache > max_cached_day_files
    || !day_cache_bytes > max_cached_total_bytes
  do
    let victim =
      Hashtbl.fold
        (fun path entry best ->
           match best with
           | None -> Some (path, entry)
           | Some (_, best_entry) ->
             if entry.last_used < best_entry.last_used then Some (path, entry)
             else best)
        day_cache
        None
    in
    match victim with
    | None -> day_cache_bytes := 0
    | Some (path, entry) ->
      Hashtbl.remove day_cache path;
      day_cache_bytes := max 0 (!day_cache_bytes - entry.size)
  done

let day_cache_remove path =
  Stdlib.Mutex.protect day_cache_mu (fun () ->
    match Hashtbl.find_opt day_cache path with
    | None -> ()
    | Some entry ->
      Hashtbl.remove day_cache path;
      day_cache_bytes := max 0 (!day_cache_bytes - entry.size))

let day_cache_store path next =
  Stdlib.Mutex.protect day_cache_mu (fun () ->
    incr day_cache_clock;
    next.last_used <- !day_cache_clock;
    match Hashtbl.find_opt day_cache path with
    | Some existing
      when existing.dev = next.dev
           && existing.ino = next.ino
           && (existing.mtime > next.mtime
               || (Float.equal existing.mtime next.mtime && existing.size > next.size)) ->
      (* A concurrent reader already cached a newer snapshot of the same inode. *)
      ()
    | Some existing ->
      day_cache_bytes := max 0 (!day_cache_bytes - existing.size) + next.size;
      Hashtbl.replace day_cache path next;
      day_cache_evict_unlocked ()
    | None ->
      day_cache_bytes := !day_cache_bytes + next.size;
      Hashtbl.replace day_cache path next;
      day_cache_evict_unlocked ())

let stat_is_settled ~now (st : Unix.stats) =
  now -. st.Unix.st_mtime >= stat_settle_window_sec
  && now -. st.Unix.st_ctime >= stat_settle_window_sec

let stats_equal (a : Unix.stats) (b : Unix.stats) =
  a.Unix.st_dev = b.Unix.st_dev
  && a.Unix.st_ino = b.Unix.st_ino
  && a.Unix.st_size = b.Unix.st_size
  && a.Unix.st_perm = b.Unix.st_perm
  && a.Unix.st_uid = b.Unix.st_uid
  && a.Unix.st_gid = b.Unix.st_gid
  && Float.equal a.Unix.st_mtime b.Unix.st_mtime
  && Float.equal a.Unix.st_ctime b.Unix.st_ctime

let stat_matches_cached (st : Unix.stats) (c : cached_day_file) =
  c.dev = st.Unix.st_dev
  && c.ino = st.Unix.st_ino
  && c.size = st.Unix.st_size
  && c.perm = st.Unix.st_perm
  && c.uid = st.Unix.st_uid
  && c.gid = st.Unix.st_gid
  && Float.equal c.mtime st.Unix.st_mtime
  && Float.equal c.ctime st.Unix.st_ctime

let slice_samples ~parsed_offset raw =
  let limit = min parsed_offset (String.length raw) in
  let prefix_len = min sample_window_bytes limit in
  let prefix_sample = String.sub raw 0 prefix_len in
  let boundary_start = max 0 (limit - sample_window_bytes) in
  let boundary_sample = String.sub raw boundary_start (limit - boundary_start) in
  (prefix_sample, boundary_sample)

let cached_entry_of_stat ~(st : Unix.stats) ~parsed_offset ~prefix_sample
    ~boundary_sample ~complete_rows_rev ~complete_valid_count ~complete_has_corrupt
    ~trailing_row =
  { dev = st.Unix.st_dev
  ; ino = st.Unix.st_ino
  ; size = st.Unix.st_size
  ; mtime = st.Unix.st_mtime
  ; ctime = st.Unix.st_ctime
  ; perm = st.Unix.st_perm
  ; uid = st.Unix.st_uid
  ; gid = st.Unix.st_gid
  ; parsed_offset
  ; prefix_sample
  ; boundary_sample
  ; complete_rows_rev
  ; complete_valid_count
  ; complete_has_corrupt
  ; trailing_row
  ; last_used = 0
  }

let load_cached_day_file path =
  let now_before = Time_compat.now () in
  match Unix.stat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    day_cache_remove path;
    Day_missing
  | exception Unix.Unix_error _ -> Day_fallback
  | st ->
    if st.Unix.st_kind <> Unix.S_REG || st.Unix.st_size > max_cached_day_file_bytes
    then Day_fallback
    else
      let settled_before = stat_is_settled ~now:now_before st in
      let cached =
        if not settled_before then None
        else
          Stdlib.Mutex.protect day_cache_mu (fun () ->
            match Hashtbl.find_opt day_cache path with
            | Some entry as hit when stat_matches_cached st entry ->
              incr day_cache_clock;
              entry.last_used <- !day_cache_clock;
              hit
            | Some _ as stale -> stale
            | None -> None)
      in
      match cached with
      | Some entry when settled_before && stat_matches_cached st entry -> Day_loaded entry
      | prev ->
        let loaded =
          Domain_pool_ref.submit_io_or_inline ~name:"audit_log:read_day_file" (fun () ->
            let now_io = Time_compat.now () in
            match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Day_missing
            | exception Unix.Unix_error _ -> Day_fallback
            | fd ->
              Fun.protect
                ~finally:(fun () ->
                  try Unix.close fd with Unix.Unix_error _ -> ())
                (fun () ->
                  match Unix.fstat fd with
                  | exception Unix.Unix_error _ -> Day_fallback
                  | opened ->
                    if opened.Unix.st_kind <> Unix.S_REG
                       || opened.Unix.st_size > max_cached_day_file_bytes
                    then Day_fallback
                    else
                      let can_cache_opened =
                        settled_before && stat_is_settled ~now:now_io opened
                      in
                      let finish_read entry =
                        match Unix.fstat fd with
                        | exception Unix.Unix_error _ -> Day_fallback
                        | after when stats_equal opened after ->
                          if can_cache_opened
                             && stat_is_settled ~now:(Time_compat.now ()) after
                          then Day_loaded entry
                          else Day_uncached entry
                        | _ -> Day_fallback
                      in
                      let full_read () =
                        let raw = read_fd_range fd ~from:0 ~len:opened.Unix.st_size in
                        if String.length raw <> opened.Unix.st_size then Day_fallback
                        else
                          let parsed_offset, complete_rows_rev, complete_valid_count,
                              complete_has_corrupt, trailing_row =
                            parse_chunk_into ~base_offset:0 ~init_rev:[]
                              ~init_valid_count:0 ~init_has_corrupt:false raw
                          in
                          let prefix_sample, boundary_sample =
                            slice_samples ~parsed_offset raw
                          in
                          finish_read
                            (cached_entry_of_stat ~st:opened ~parsed_offset
                               ~prefix_sample ~boundary_sample
                               ~complete_rows_rev ~complete_valid_count
                               ~complete_has_corrupt ~trailing_row)
                      in
                      match prev with
                      | Some c when can_cache_opened && stat_matches_cached opened c ->
                        Day_loaded c
                      | Some c
                        when can_cache_opened
                             && c.dev = opened.Unix.st_dev
                             && c.ino = opened.Unix.st_ino
                             && opened.Unix.st_size > c.size
                             && c.parsed_offset <= opened.Unix.st_size ->
                        let prefix_len = String.length c.prefix_sample in
                        let boundary_len = String.length c.boundary_sample in
                        let prefix_ok =
                          prefix_len = 0
                          || String.equal
                               (read_fd_range fd ~from:0 ~len:prefix_len)
                               c.prefix_sample
                        in
                        let boundary_ok =
                          prefix_ok
                          && (boundary_len = 0
                              || String.equal
                                   (read_fd_range fd
                                      ~from:(c.parsed_offset - boundary_len)
                                      ~len:boundary_len)
                                   c.boundary_sample)
                        in
                        if not boundary_ok then full_read ()
                        else
                          let delta_len = opened.Unix.st_size - c.parsed_offset in
                          let delta =
                            read_fd_range fd ~from:c.parsed_offset ~len:delta_len
                          in
                          if String.length delta <> delta_len then Day_fallback
                          else
                            let parsed_offset, complete_rows_rev, complete_valid_count,
                                complete_has_corrupt, trailing_row =
                              parse_chunk_into ~base_offset:c.parsed_offset
                                ~init_rev:c.complete_rows_rev
                                ~init_valid_count:c.complete_valid_count
                                ~init_has_corrupt:c.complete_has_corrupt delta
                            in
                            let prefix_sample =
                              if String.length c.prefix_sample = sample_window_bytes
                              then c.prefix_sample
                              else
                                read_fd_range fd ~from:0
                                  ~len:(min sample_window_bytes parsed_offset)
                            in
                            let boundary_sample =
                              if parsed_offset = c.parsed_offset then c.boundary_sample
                              else
                                let delta_parsed = parsed_offset - c.parsed_offset in
                                if delta_parsed >= sample_window_bytes then
                                  String.sub delta
                                    (delta_parsed - sample_window_bytes)
                                    sample_window_bytes
                                else
                                  let b_start = max 0 (parsed_offset - sample_window_bytes) in
                                  read_fd_range fd ~from:b_start
                                    ~len:(parsed_offset - b_start)
                            in
                            finish_read
                              (cached_entry_of_stat ~st:opened ~parsed_offset
                                 ~prefix_sample ~boundary_sample
                                 ~complete_rows_rev ~complete_valid_count
                                 ~complete_has_corrupt ~trailing_row)
                      | Some _ | None -> full_read ()))
        in
        (match loaded with
         | Day_missing ->
           day_cache_remove path;
           Day_missing
         | Day_fallback -> Day_fallback
         | Day_uncached entry -> Day_uncached entry
         | Day_loaded entry ->
           day_cache_store path entry;
           Day_loaded entry)

type cached_audit_dir = {
  dir_st : Unix.stats;
  dir_entries : string list;
  mutable dir_last_used : int;
}

let audit_dir_cache_mu = Stdlib.Mutex.create ()
let audit_dir_cache : (string, cached_audit_dir) Hashtbl.t = Hashtbl.create 16
let audit_dir_cache_max = 64
let audit_dir_cache_clock = ref 0

let audit_dir_cache_remove key =
  Stdlib.Mutex.protect audit_dir_cache_mu (fun () -> Hashtbl.remove audit_dir_cache key)

let audit_dir_cache_store key dir_st dir_entries =
  Stdlib.Mutex.protect audit_dir_cache_mu (fun () ->
    incr audit_dir_cache_clock;
    Hashtbl.replace audit_dir_cache key
      { dir_st; dir_entries; dir_last_used = !audit_dir_cache_clock };
    while Hashtbl.length audit_dir_cache > audit_dir_cache_max do
      let victim =
        Hashtbl.fold
          (fun k v best ->
             match best with
             | None -> Some (k, v)
             | Some (_, bv) -> if v.dir_last_used < bv.dir_last_used then Some (k, v) else best)
          audit_dir_cache
          None
      in
      match victim with
      | None -> ()
      | Some (k, _) -> Hashtbl.remove audit_dir_cache k
    done)

let list_audit_dir_cached ~cache_prefix path ~compute =
  let key = cache_prefix ^ path in
  let now_before = Time_compat.now () in
  match Unix.stat path with
  | exception Unix.Unix_error _ ->
    audit_dir_cache_remove key;
    (None, [])
  | st ->
    if st.Unix.st_kind <> Unix.S_DIR then begin
      audit_dir_cache_remove key;
      (None, [])
    end else
      let settled_before = stat_is_settled ~now:now_before st in
      let hit =
        if not settled_before then None
        else
          Stdlib.Mutex.protect audit_dir_cache_mu (fun () ->
            match Hashtbl.find_opt audit_dir_cache key with
            | Some cached when stats_equal st cached.dir_st ->
              incr audit_dir_cache_clock;
              cached.dir_last_used <- !audit_dir_cache_clock;
              Some (Some cached.dir_st, cached.dir_entries)
            | Some _ | None -> None)
      in
      match hit with
      | Some result -> result
      | None ->
        (match Sys.readdir path with
         | exception Sys_error _ -> (None, [])
         | raw ->
           let entries = compute raw in
           if settled_before then begin
             match Unix.stat path with
             | after
               when after.Unix.st_kind = Unix.S_DIR
                    && stats_equal st after
                    && stat_is_settled ~now:(Time_compat.now ()) after ->
               audit_dir_cache_store key after entries;
               (Some after, entries)
             | _ | (exception Unix.Unix_error _) -> (None, entries)
           end else (None, entries))

let compute_month_dirs raw =
  let acc = ref [] in
  for i = 0 to Array.length raw - 1 do
    let d = Array.unsafe_get raw i in
    if String.length d = 7
       && d.[4] = '-'
       && Option.is_some (int_of_string_opt (String.sub d 0 4))
    then acc := d :: !acc
  done;
  List.sort (fun a b -> String.compare b a) !acc

let compute_day_files raw =
  let acc = ref [] in
  for i = 0 to Array.length raw - 1 do
    let f = Array.unsafe_get raw i in
    if Filename.check_suffix f ".jsonl" then acc := f :: !acc
  done;
  List.sort (fun left right -> Dated_jsonl.Layout.compare_day_files right left) !acc

let list_audit_month_dirs base_dir =
  snd (list_audit_dir_cached ~cache_prefix:"m:" base_dir ~compute:compute_month_dirs)

let list_audit_day_files month_path =
  snd (list_audit_dir_cached ~cache_prefix:"d:" month_path ~compute:compute_day_files)

let audit_base_dir (config : config) =
  Dated_jsonl.Store.dir
    (Dated_jsonl.Store.at
       (Workspace_utils.dated_store_root config)
       Dated_jsonl.Store.Root.Audit)

let lookup_settled_cached_day_file path =
  let now = Time_compat.now () in
  match Unix.stat path with
  | exception Unix.Unix_error _ -> None
  | st ->
    if st.Unix.st_kind <> Unix.S_REG
       || st.Unix.st_size > max_cached_day_file_bytes
       || not (stat_is_settled ~now st)
    then None
    else
      Stdlib.Mutex.protect day_cache_mu (fun () ->
        match Hashtbl.find_opt day_cache path with
        | Some cached when stat_matches_cached st cached ->
          incr day_cache_clock;
          cached.last_used <- !day_cache_clock;
          Some cached
        | Some _ | None -> None)

let cached_day_valid_and_clean (cached : cached_day_file) =
  match cached.trailing_row with
  | None -> (cached.complete_valid_count, not cached.complete_has_corrupt)
  | Some (Ok _) -> (cached.complete_valid_count + 1, not cached.complete_has_corrupt)
  | Some (Error _) -> (cached.complete_valid_count, false)

let add_stat_stamp buf (st : Unix.stats) =
  Printf.bprintf buf "%d:%d:%d:%.9f:%.9f|"
    st.Unix.st_dev st.Unix.st_ino st.Unix.st_size st.Unix.st_mtime st.Unix.st_ctime

let settled_tail_stamp ~n (config : config) : string option =
  if n <= 0 then Some "0"
  else
    let base_dir = audit_base_dir config in
    match list_audit_dir_cached ~cache_prefix:"m:" base_dir ~compute:compute_month_dirs with
    | None, _ -> None
    | Some root_st, months ->
      let buf = Buffer.create 160 in
      Buffer.add_string buf "v1|";
      add_stat_stamp buf root_st;
      let covered = ref 0 in
      let exception Unsettled in
      let exception Done in
      (try
         List.iter
           (fun m ->
              if !covered >= n then raise_notrace Done;
              let month_path = Filename.concat base_dir m in
              match
                list_audit_dir_cached ~cache_prefix:"d:" month_path
                  ~compute:compute_day_files
              with
              | None, _ -> raise_notrace Unsettled
              | Some month_st, days ->
                Buffer.add_string buf m;
                Buffer.add_char buf '=';
                add_stat_stamp buf month_st;
                List.iter
                  (fun d ->
                     if !covered >= n then raise_notrace Done;
                     let path = Filename.concat month_path d in
                     match lookup_settled_cached_day_file path with
                     | None -> raise_notrace Unsettled
                     | Some cached ->
                       let valid_count, clean = cached_day_valid_and_clean cached in
                       if not clean then raise_notrace Unsettled;
                       Printf.bprintf buf "%s:%d:%d:%d:%.9f:%.9f|"
                         d cached.dev cached.ino cached.size cached.mtime cached.ctime;
                       covered := !covered + valid_count;
                       if !covered >= n then raise_notrace Done)
                  days)
           months;
         Some (Buffer.contents buf)
       with
       | Done -> Some (Buffer.contents buf)
       | Unsettled -> None)

let read_entries_cached ~n base_dir =
  if n <= 0 then Some []
  else
    let collected = ref [] in
    let count = ref 0 in
    let exception Done in
    let exception Fallback in
    let visit_row row =
      if !count >= n then raise_notrace Done;
      collected := row :: !collected;
      incr count;
      if !count >= n then raise_notrace Done
    in
    try
      List.iter
        (fun m ->
           let month_path = Filename.concat base_dir m in
           List.iter
             (fun d ->
                if !count >= n then raise_notrace Done;
                let path = Filename.concat month_path d in
                match load_cached_day_file path with
                | Day_missing -> ()
                | Day_fallback -> raise_notrace Fallback
                | Day_uncached cached | Day_loaded cached ->
                  Option.iter visit_row cached.trailing_row;
                  List.iter visit_row cached.complete_rows_rev)
             (list_audit_day_files month_path))
        (list_audit_month_dirs base_dir);
      Some !collected
    with
    | Done -> Some !collected
    | Fallback -> None

(** Read recent audit entries from the date-split store.
    Structural parse failures go through [parse_entries] ERROR path. *)
let read_entries ?(n = 10_000) (config : config) : audit_entry list =
  let base_dir = audit_base_dir config in
  let decoded =
    match read_entries_cached ~n base_dir with
    | Some rows -> rows
    | None ->
      let store = get_audit_store config in
      Dated_jsonl.filter_map_recent store n ~f:(fun json ->
        Some (entry_of_json_r json))
  in
  collect_entries decoded

(* The bounds below are compared against day-file names, so this has to be the
   key [Jsonl_writer] wrote them with. Formatting it here a second time meant a
   change to the writer's layout would silently narrow every audit range
   instead of failing (#29358).

   The year guard stays: [day_key] is total and formats out-of-range years
   into a string that no longer sorts against the stored names, and this
   function's [None] is what tells the caller the bound is unusable. *)
let utc_date_of_timestamp timestamp =
  match Unix.gmtime timestamp with
  | tm ->
    let year = tm.Unix.tm_year + 1900 in
    if year < 0 || year > 9999
    then None
    else Some (Jsonl_writer.day_key ~ts:timestamp)
  | exception Invalid_argument _
  | exception Unix.Unix_error _ -> None
;;

let optional_date_bound = function
  | None -> Some None
  | Some timestamp ->
    Option.map (fun date -> Some date) (utc_date_of_timestamp timestamp)
;;

(* [n] counts entries that satisfy [keep]. {!read_entries} counts rows read, so
   a caller that filters afterwards has to guess how wide a window its matches
   need — the audit store carries every agent's actions, and one busy agent
   fills any fixed guess. *)
(* Day-file names sort lexicographically, so these two bound the range from
   outside: no stored day can precede the first or follow the second. They mean
   "this side is unbounded", which is why an absent [since]/[until] maps onto
   them rather than onto a narrower guess. *)
let earliest_day_bound = "0000-01-01"
let latest_day_bound = "9999-12-31"

let report_corrupt_reasons ~total_rows (reasons : string list) =
  let err_count =
    List.fold_left
      (fun errc reason ->
         let errc = errc + 1 in
         if errc <= max_logged_errors then
           Log.Misc.error "audit_log: corrupt entry (#%d): %s" errc reason;
         errc)
      0
      reasons
  in
  if err_count > 0 then
    Log.Misc.error "audit_log: %d/%d entries failed to parse (possible corruption)%s"
      err_count total_rows
      (if err_count > max_logged_errors
       then Printf.sprintf " (%d more suppressed)" (err_count - max_logged_errors)
       else "")

let read_entries_matching_cached ~month_is_in_range ~day_is_in_range ~n ~keep base_dir =
  if n <= 0 then Some ([], [], 0)
  else
    let malformed = ref [] in
    let matched = ref [] in
    let count = ref 0 in
    let exception Done in
    let exception Fallback in
    let visit_row = function
      | Ok entry ->
        if keep entry then begin
          matched := entry :: !matched;
          incr count;
          if !count >= n then raise_notrace Done
        end
      | Error reason ->
        malformed := reason :: !malformed
    in
    try
      List.iter
        (fun m ->
           if month_is_in_range m then begin
             let month_path = Filename.concat base_dir m in
             List.iter
               (fun d ->
                  if !count >= n then raise_notrace Done;
                  if day_is_in_range m d then begin
                    let path = Filename.concat month_path d in
                    match load_cached_day_file path with
                    | Day_missing -> ()
                    | Day_fallback -> raise_notrace Fallback
                    | Day_uncached cached | Day_loaded cached ->
                      Option.iter visit_row cached.trailing_row;
                      List.iter visit_row cached.complete_rows_rev
                  end)
               (list_audit_day_files month_path)
           end)
        (list_audit_month_dirs base_dir);
      Some (!malformed, !matched, !count)
    with
    | Done -> Some (!malformed, !matched, !count)
    | Fallback -> None

let read_entries_matching ?(n = 10_000) ?since ?until ~keep (config : config)
  : audit_entry list
  =
  let base_dir = audit_base_dir config in
  (* Corrupt rows are collected but not counted: they are not entries the
     caller asked for, and letting them consume the budget would make [n] mean
     "matches, unless the store is damaged". They still reach
     [collect_entries] so corruption keeps being reported. *)
  let fallback_unbounded () =
    let store = get_audit_store config in
    let malformed = ref [] in
    let select json =
      match entry_of_json_r json with
      | Ok entry when keep entry -> Some (Ok entry)
      | Ok _ -> None
      | Error _ as corrupt ->
        malformed := corrupt :: !malformed;
        None
    in
    let matched = Dated_jsonl.collect_matching store n ~f:select in
    collect_entries (List.rev !malformed @ matched)
  in
  let fallback_range ~since_bound ~until_bound =
    let store = get_audit_store config in
    let malformed = ref [] in
    let select json =
      match entry_of_json_r json with
      | Ok entry when keep entry -> Some (Ok entry)
      | Ok _ -> None
      | Error _ as corrupt ->
        malformed := corrupt :: !malformed;
        None
    in
    let matched =
      Dated_jsonl.collect_matching_range
        store ~since:since_bound ~until:until_bound n ~f:select
    in
    collect_entries (List.rev !malformed @ matched)
  in
  let finish_cached (malformed_rev, matched, matched_count) =
    if malformed_rev <> [] then begin
      let malformed = List.rev malformed_rev in
      report_corrupt_reasons
        ~total_rows:(List.length malformed + matched_count)
        malformed
    end;
    matched
  in
  match optional_date_bound since, optional_date_bound until with
  | Some since_day, Some until_day
    when Option.is_some since_day || Option.is_some until_day ->
    (* DET-OK: range identities, not a guess at a missing value. *)
    let since_bound = Option.value ~default:earliest_day_bound since_day in
    let until_bound = Option.value ~default:latest_day_bound until_day in
    (match
       Dated_jsonl.Layout.parse_date since_bound,
       Dated_jsonl.Layout.parse_date until_bound
     with
     | Some (since_month, since_d), Some (until_month, until_d)
       when String.compare since_bound until_bound <= 0 ->
       let month_is_in_range m =
         String.compare m since_month >= 0 && String.compare m until_month <= 0
       in
       let day_is_in_range m day_file =
         let day = Dated_jsonl.Layout.day_number_of_day_file_name day_file in
         not
           ((String.equal m since_month && String.compare day since_d < 0)
            || (String.equal m until_month && String.compare day until_d > 0))
       in
       (match
          read_entries_matching_cached
            ~month_is_in_range ~day_is_in_range ~n ~keep base_dir
        with
        | Some result -> finish_cached result
        | None -> fallback_range ~since_bound ~until_bound)
     | Some _, Some _ | None, _ | _, None -> [])
  | Some _, Some _ | None, _ | _, None ->
    (match
       read_entries_matching_cached
         ~month_is_in_range:(fun _ -> true)
         ~day_is_in_range:(fun _ _ -> true)
         ~n ~keep base_dir
     with
     | Some result -> finish_cached result
     | None -> fallback_unbounded ())

(** Append a single entry to the audit log (thread-safe via Dated_jsonl). *)
let append_entry (config : config) (entry : audit_entry) =
  let store = get_audit_store config in
  Dated_jsonl.append store (entry_to_json entry)

(** {1 Logging API} *)

(* ── Audit-event helpers ─────────────────────────────────────────── *)

(** Derive a stable lexicographic ID from timestamp and entry content.
    Format: [aud-<16-hex-ms>-<8-hex-content-hash>] *)
let audit_entry_id ~timestamp ~agent_id ~action =
  let ms = Int64.of_float (timestamp *. 1000.0) in
  (* SHA-256, not Stdlib.Digest (MD5): this suffix is the collision boundary
     for an audit key, and it is truncated to 32 bits on top (#26720). *)
  let hash =
    Agent_core_sha256.(
      digest_string
        (agent_id ^ action_to_string action ^ Printf.sprintf "%.6f" timestamp)
      |> to_hex)
  in
  Printf.sprintf "aud-%016Lx-%s" ms (String.sub hash 0 8)

(** Map outcome + action to O2 severity string. *)
let audit_severity ~action ~outcome =
  match outcome with
  | Failure _ ->
    (match action with
     | AuthFailure | CircuitOpen -> "error"
     | ClaimTask | StartTask | DoneTask | CancelTask | ReleaseTask | Broadcast
     | Suspend | ToolCall _ | AuthSuccess | CircuitClose | SearchRefinement
     | GateDecision _ | RuntimeConfigWrite | Custom _ | Unknown _ ->
       "warn")
  | Success ->
    (match action with
     | AuthSuccess -> "info"
     | GateDecision d ->
       (match d with
        | Gate_deny | Gate_unauthorized -> "warn"
        | Gate_allow | Gate_require_confirmation | Gate_confirm | Gate_expired
        | Gate_other _ ->
          "info")
     | CircuitClose -> "warn"
     (* A successful runtime.toml write rewrites global keeper routing
        (the highest-risk surface). Surface it above
        routine info events so a severity-filtered audit scan catches it,
        consistent with [CircuitClose] elevating a significant successful
        transition to "warn". *)
     | RuntimeConfigWrite -> "warn"
     (* Enumerated rather than swept into a default: severity is the key a
        filtered audit scan reads, and RuntimeConfigWrite above is the record
        of what a default costs -- it sat at "info" until someone noticed the
        highest-risk surface was hidden among routine events. A new action now
        has to be placed here. *)
     | ClaimTask | StartTask | DoneTask | CancelTask | ReleaseTask | Broadcast
     | Suspend | ToolCall _ | AuthFailure | CircuitOpen | SearchRefinement
     | Custom _ | Unknown _ ->
       "info")

(** Build a human-readable one-line summary from action + details. *)
let audit_summary ~action ~details =
  let kind = action_to_string action in
  let extract_str key =
    match details with
    | `Assoc fields -> (match List.assoc_opt key fields with
      | Some (`String v) -> Some (audit_summary_field v)
      | _ -> None)
    | _ -> None
  in
  let extract_bool key =
    match details with
    | `Assoc fields -> (match List.assoc_opt key fields with
      | Some (`Bool v) -> Some v
      | _ -> None)
    | _ -> None
  in
  let extract_string_list key =
    match details with
    | `Assoc fields ->
      (match List.assoc_opt key fields with
       | Some (`List values) ->
         let rec loop acc = function
           | [] -> Some (List.rev acc)
           | `String v :: rest ->
             loop (audit_summary_field v :: acc) rest
           | _ :: _ -> None
         in
         loop [] values
       | _ -> None)
    | _ -> None
  in
  match action with
  | ToolCall name ->
    (match extract_str "error_msg" with
     | Some msg -> Printf.sprintf "tool_call:%s failed: %s" name msg
     | None -> Printf.sprintf "tool_call:%s" name)
  | GateDecision d ->
    let decision = gate_audit_decision_to_string d in
    (match extract_str "action_type" with
     | Some at -> Printf.sprintf "gate %s: %s" decision at
     | None -> Printf.sprintf "gate %s" decision)
  | Broadcast ->
    (match extract_str "preview" with
     | Some p -> Printf.sprintf "broadcast: %s" p
     | None -> "broadcast")
  | Suspend ->
    (match extract_str "target_agent" with
     | Some t -> Printf.sprintf "suspend %s" t
     | None -> "suspend")
  | CancelTask ->
    (match extract_str "task_id" with
     | Some id -> Printf.sprintf "cancel_task %s" id
     | None -> "cancel_task")
  | RuntimeConfigWrite ->
    (match extract_str "operation" with
     | Some "assignment" ->
       (match extract_str "keeper_name", extract_str "runtime_id", extract_bool "cleared" with
        | Some keeper, _, Some true ->
          Printf.sprintf "runtime.toml assignment cleared: %s" keeper
        | Some keeper, Some runtime_id, _ ->
          Printf.sprintf "runtime.toml assignment updated: %s -> %s" keeper runtime_id
        | Some keeper, None, _ ->
          Printf.sprintf "runtime.toml assignment updated: %s" keeper
        | None, _, _ -> "runtime.toml assignment updated")
     | Some "routing" ->
       (match
          ( extract_str "lane"
          , extract_str "runtime_id"
          , extract_string_list "runtime_ids"
          , extract_bool "cleared" )
        with
        | Some lane, _, _, Some true ->
          Printf.sprintf "runtime.toml routing cleared: %s" lane
        | Some lane, Some runtime_id, _, _ ->
          Printf.sprintf "runtime.toml routing updated: %s -> %s" lane runtime_id
        | Some lane, None, Some runtime_ids, _ ->
          Printf.sprintf
            "runtime.toml routing updated: %s -> [%s]"
            lane
            (String.concat ", " runtime_ids)
        | Some lane, None, None, _ ->
          Printf.sprintf "runtime.toml routing updated: %s" lane
        | None, _, _, _ -> "runtime.toml routing updated")
     | Some "raw_save" ->
       (match extract_str "path" with
        | Some p -> Printf.sprintf "runtime.toml raw save: %s" p
        | None -> "runtime.toml raw save")
     | Some "reload" ->
       (match extract_str "path" with
        | Some p -> Printf.sprintf "runtime.toml reloaded: %s" p
        | None -> "runtime.toml reloaded")
     | _ ->
       (match extract_str "path" with
        | Some p -> Printf.sprintf "runtime.toml updated: %s" p
        | None -> "runtime.toml updated"))
  | ClaimTask | StartTask | DoneTask | ReleaseTask | AuthSuccess | AuthFailure | CircuitOpen
  | CircuitClose | SearchRefinement | Custom _ | Unknown _ -> kind

(** Extract primary target from action + details, if any. *)
let audit_target ~action ~details =
  let extract_str key =
    match details with
    | `Assoc fields -> (match List.assoc_opt key fields with
      | Some (`String v) -> Some v
      | _ -> None)
    | _ -> None
  in
  match action with
  | ToolCall name -> Some name
  | GateDecision _ -> extract_str "action_type"
  | ClaimTask | StartTask | DoneTask | CancelTask | ReleaseTask ->
    extract_str "task_id"
  | Suspend -> extract_str "target_agent"
  | RuntimeConfigWrite -> extract_str "path"
  | Custom _ -> extract_str "tool_name"
  (* These carry no single subject worth putting in the one-line summary. *)
  | Broadcast | AuthSuccess | AuthFailure | CircuitOpen | CircuitClose
  | SearchRefinement | Unknown _ ->
    None

let audit_event_severity (entry : audit_entry) =
  audit_severity ~action:entry.action ~outcome:entry.outcome

let audit_event_json_uncached (entry : audit_entry) =
  let kind = action_to_string entry.action in
  let id =
    audit_entry_id ~timestamp:entry.timestamp ~agent_id:entry.agent_id
      ~action:entry.action
  in
  let target = audit_target ~action:entry.action ~details:entry.details in
  let fields =
    [
      ("id", `String id);
      ("ts", `String (Masc_domain.iso8601_of_unix_seconds entry.timestamp));
      ("actor", `String entry.agent_id);
      ("kind", `String kind);
      ("summary", `String (audit_summary ~action:entry.action ~details:entry.details));
      ("severity", `String (audit_event_severity entry));
    ]
  in
  let fields =
    match target with
    | Some value -> ("target", `String value) :: fields
    | None -> fields
  in
  let fields =
    if entry.details = `Null then fields else ("payload", entry.details) :: fields
  in
  `Assoc fields

(* Fixed-size lock-free physical-equality cache for immutable [audit_entry]
   records served from the day-file cache: avoids repeating SHA-256 + gmtime +
   JSON allocation on every [/api/v1/audit] poll. *)
let event_json_cache_mask = 2047
let event_json_cache : (audit_entry * Yojson.Safe.t) option Atomic.t array =
  Array.init (event_json_cache_mask + 1) (fun _ -> Atomic.make None)

let audit_event_json (entry : audit_entry) =
  let idx =
    (Hashtbl.hash entry.timestamp lxor (Hashtbl.hash entry.agent_id * 31))
    land event_json_cache_mask
  in
  let slot = Array.unsafe_get event_json_cache idx in
  match Atomic.get slot with
  | Some (cached_entry, cached_json) when cached_entry == entry -> cached_json
  | Some _ | None ->
    let json = audit_event_json_uncached entry in
    Atomic.set slot (Some (entry, json));
    json

(* One predicate for the query filters, so the read and the projection cannot
   disagree about what the caller asked for. A reader that counts matches needs
   this decision before it pages; leaving it inside the projection is what made
   the endpoint read a multiple of [limit] and hope. *)
let audit_entry_matches ?actor ?kind ?severity ?since ?until =
  let actor = Option.map String.trim actor in
  let kind = Option.map String.trim kind in
  let severity = Option.map String.trim severity in
  fun (entry : audit_entry) ->
    (match actor with
     | None -> true
     | Some value -> String.equal entry.agent_id value)
    && (match kind with
        | None -> true
        | Some value ->
          String.starts_with ~prefix:value (action_to_string entry.action))
    && (match since with None -> true | Some value -> entry.timestamp >= value)
    && (match until with None -> true | Some value -> entry.timestamp <= value)
    && (match severity with
        | None -> true
        | Some value -> String.equal (audit_event_severity entry) value)

let audit_events_response_json ?actor ?kind ?severity ?since ?until ~limit
    (entries : audit_entry list) =
  let filtered =
    if Option.is_none actor
       && Option.is_none kind
       && Option.is_none severity
       && Option.is_none since
       && Option.is_none until
    then entries
    else
      List.filter (audit_entry_matches ?actor ?kind ?severity ?since ?until) entries
  in
  let total = List.length filtered in
  let drop_n = max 0 (total - limit) in
  let rec drop_front n = function
    | list when n <= 0 -> list
    | [] -> []
    | _ :: rest -> drop_front (n - 1) rest
  in
  let page = drop_front drop_n filtered in
  `Assoc
    [
      ("entries", `List (List.map audit_event_json page));
      ("count", `Int (List.length page));
    ]

let log_action
    (config : config)
    ~agent_id
    ~action
    ?(details : Yojson.Safe.t = `Null)
    ?(trace_id : string option)
    ~outcome
    () =
  let entry = {
    timestamp = Time_compat.now ();
    agent_id;
    action;
    details;
    outcome;
    trace_id;
  } in
  append_entry config entry;
  (* Publish to the MASC event bus for real-time SSE streaming. *)
  let id = audit_entry_id ~timestamp:entry.timestamp ~agent_id ~action in
  let ts = Masc_domain.iso8601_of_unix_seconds entry.timestamp in
  let kind = action_to_string action in
  let severity = audit_severity ~action ~outcome in
  let summary = audit_summary ~action ~details in
  let target = audit_target ~action ~details in
  let payload_opt = if details = `Null then None else Some details in
  Keeper_event_publisher.publish_audit_event ~id ~ts ~actor:agent_id ~kind ?target
    ~summary ~severity ?payload:payload_opt ()

(** Convenience functions for common events *)

let log_broadcast config ~agent_id ~message_preview () =
  (* Truncate message for privacy/size *)
  let preview = preview ~max_len:100 message_preview in
  log_action config ~agent_id ~action:Broadcast
    ~details:(`Assoc [("preview", `String preview)])
    ~outcome:Success ()

let outcome_of ~success ~error_msg =
  if success then Success else Failure (Option.value error_msg ~default:"unknown")

let log_tool_call config ~agent_id ~tool_name ~success ~error_msg ?trace_id () =
  log_action config ~agent_id ~action:(ToolCall tool_name) ?trace_id
    ~outcome:(outcome_of ~success ~error_msg) ()

let remove_assoc_keys keys fields =
  List.filter (fun (key, _) -> not (List.mem key keys)) fields

let log_non_public_tool_call config ~agent_id ~tool_name ~success ~error_msg
    ?(details : Yojson.Safe.t = `Null) ?trace_id () =
  let outcome = outcome_of ~success ~error_msg in
  let details =
    match details with
    | `Assoc fields ->
        let caller_fields = remove_assoc_keys [ "surface"; "tool_name" ] fields in
        `Assoc
          (("surface", `String "non_public")
          :: ("tool_name", `String tool_name)
          :: caller_fields)
    | other ->
        `Assoc
          [
            ("surface", `String "non_public");
            ("tool_name", `String tool_name);
            ("context", other);
          ]
  in
  log_action config ~agent_id ~action:(Custom "non_public_tool_call")
    ~details ?trace_id ~outcome ()

let log_client_tool_host_failure config ~agent_id ~reported_agent ~client_name ~tool_name
    ~transport ~message ?phase ?request_id ?session_id ?trace_id ?timeout_ms () =
  let details =
    `Assoc
      (List.filter_map
         Fun.id
         [
           Some ("reported_agent", `String reported_agent);
           Some ("client_name", `String client_name);
           Some ("tool_name", `String tool_name);
           Some ("transport", `String transport);
           Option.map (fun value -> ("phase", `String value)) phase;
           Option.map (fun value -> ("request_id", `String value)) request_id;
           Option.map (fun value -> ("session_id", `String value)) session_id;
           Option.map (fun value -> ("timeout_ms", `Int value)) timeout_ms;
         ])
  in
  log_action config ~agent_id ~action:(Custom "client_tool_host_failure")
    ~details ?trace_id ~outcome:(Failure message) ()

let log_gate_decision config ~agent_id ~trace_id ~decision ~action_type ~confirmation_state () =
  log_action config ~agent_id
    ~action:(GateDecision decision)
    ~trace_id
    ~details:(`Assoc [
      ("action_type", `String action_type);
      ("confirmation_state", `String confirmation_state);
    ])
    ~outcome:Success ()

(** Render the result of an audit write as a two-field JSON receipt.
    [Ok ()] becomes [{"recorded": true}]; [Error detail] becomes
    [{"recorded": false, "error": <detail>}] with the detail passed through
    {!Observability_redact.redact_text}. *)
let write_result_to_json = function
  | Ok () -> `Assoc [("recorded", `Bool true)]
  | Error detail ->
    `Assoc [
      ("recorded", `Bool false);
      ("error", `String (Observability_redact.redact_text detail));
    ]
