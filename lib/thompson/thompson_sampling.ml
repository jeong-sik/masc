(** Thompson Sampling — per-agent Beta-prior bookkeeping.

    Maintains per-agent Beta(alpha, beta) priors fed by vote and quality
    feedback, persisted across restarts.  The selection engine that once
    consumed these priors was removed as production-unreachable
    (2026-07-21 dead-surface audit); the priors themselves stay live as
    the reputation/confidence source for dashboard and board surfaces. *)

type quality_verdict =
  | Pass
  | Warn of string
  | Fail of string

(** {1 Types} *)

type agent_stats = {
  name : string;
  (* Thompson Sampling Beta distribution parameters *)
  mutable alpha : float;
  mutable beta : float;
  (* Selection tracking *)
  mutable selections : int;
  mutable last_selected_at : float;
  (* Quality metrics *)
  mutable total_votes_up : int;
  mutable total_votes_down : int;
  mutable posts_created : int;
  mutable comments_created : int;
  mutable skips : int;
  (* Timestamp *)
  mutable updated_at : float;
}

(** {1 Internal State} *)

(** Agent stats table, keyed by name *)
let stats_table : (string, agent_stats) Hashtbl.t = Hashtbl.create 16

(** Pending votes for batch update at tick end *)
let pending_votes : (string, int * int) Hashtbl.t = Hashtbl.create 16

(** Base path for stats storage (cluster root, e.g. ~/me) *)
let base_path_ref : string option ref = ref None

(** Mutex protecting stats_table, pending_votes, and base_path_ref. *)
let ts_mu = Eio.Mutex.create ()
let with_ts_rw f = Eio_guard.with_mutex ts_mu f
let with_ts_ro f = Eio_guard.with_mutex_ro ts_mu f

let clear_in_memory_stats_unlocked () =
  Hashtbl.clear stats_table;
  Hashtbl.clear pending_votes
;;

(** Set base path for stats storage. Call during server init. *)
let set_base_path path =
  with_ts_rw (fun () ->
    let changed =
      match !base_path_ref with
      | Some current -> not (String.equal current path)
      | None -> true
    in
    if changed then clear_in_memory_stats_unlocked ();
    base_path_ref := Some path)

(** Stats file path — uses cluster base_path, not execution directory *)
let stats_path () =
  let base = match !base_path_ref with
    | Some p -> p
    | None ->
        (* Fallback: try to get from environment or use current dir *)
        Env_config_core.base_path ()
  in
  let masc_dir = Workspace_utils.masc_dir_from_base_path ~base_path:base in
  Fs_compat.mkdir_p masc_dir;
  Filename.concat masc_dir "autonomy_stats.jsonl"

(** Minimum prior value for numerical stability in Beta distribution sampling. *)
let min_prior = 0.1

(** {1 Statistics Management} *)

(** Create default stats for a new agent *)
let make_default_stats name =
  let now = Time_compat.now () in
  {
    name;
    alpha = 1.0;
    beta = 1.0;
    selections = 0;
    last_selected_at = now;  (* Initialize to now to avoid immediate starvation *)
    total_votes_up = 0;
    total_votes_down = 0;
    posts_created = 0;
    comments_created = 0;
    skips = 0;
    updated_at = now;
  }

let get_stats name =
  with_ts_rw (fun () ->
    match Hashtbl.find_opt stats_table name with
    | Some s -> s
    | None ->
        let s = make_default_stats name in
        Hashtbl.add stats_table name s;
        s)

let get_all_stats () =
  with_ts_ro (fun () ->
    Hashtbl.fold (fun _ v acc -> v :: acc) stats_table [])

(** {1 JSON Serialization} *)

let stats_to_json (s : agent_stats) : Yojson.Safe.t =
  `Assoc [
    ("name", `String s.name);
    ("alpha", `Float s.alpha);
    ("beta", `Float s.beta);
    ("selections", `Int s.selections);
    ("last_selected_at", `Float s.last_selected_at);
    ("total_votes_up", `Int s.total_votes_up);
    ("total_votes_down", `Int s.total_votes_down);
    ("posts_created", `Int s.posts_created);
    ("comments_created", `Int s.comments_created);
    ("skips", `Int s.skips);
    ("updated_at", `Float s.updated_at);
  ]

let copy_stats (s : agent_stats) : agent_stats =
  (* Deep-copy safe: [agent_stats] stores only immutable primitive fields, no
     nested refs/containers that could alias the live table. *)
  {
    name = s.name;
    alpha = s.alpha;
    beta = s.beta;
    selections = s.selections;
    last_selected_at = s.last_selected_at;
    total_votes_up = s.total_votes_up;
    total_votes_down = s.total_votes_down;
    posts_created = s.posts_created;
    comments_created = s.comments_created;
    skips = s.skips;
    updated_at = s.updated_at;
  }

let stats_of_json (json : Yojson.Safe.t) : agent_stats option =
  let name = Json_util.get_string_with_default json ~key:"name" ~default:"" in
  if String.equal (String.trim name) "" then
    None
  else match Json_util.get_float json "alpha", Json_util.get_float json "beta" with
  | None, _ | _, None -> None
  | Some alpha, Some beta ->
  let selections = Json_util.get_int json "selections" |> Option.value ~default:0 in
  let last_selected_at = Json_util.get_float json "last_selected_at" |> Option.value ~default:0.0 in
  let total_votes_up = Json_util.get_int json "total_votes_up" |> Option.value ~default:0 in
  let total_votes_down = Json_util.get_int json "total_votes_down" |> Option.value ~default:0 in
  let posts_created = Json_util.get_int json "posts_created" |> Option.value ~default:0 in
  let comments_created = Json_util.get_int json "comments_created" |> Option.value ~default:0 in
  let skips = Json_util.get_int json "skips" |> Option.value ~default:0 in
  let updated_at = Json_util.get_float json "updated_at" |> Option.value ~default:0.0 in
  Some {
    name;
    alpha = Float.max min_prior alpha;
    beta = Float.max min_prior beta;
    selections;
    last_selected_at;
    total_votes_up;
    total_votes_down;
    posts_created;
    comments_created;
    skips;
    updated_at;
  }

let apply_vote_counts ~decay (s : agent_stats) ~votes_up ~votes_down =
  let total = votes_up + votes_down in
  if total > 0 then begin
    let success_rate = float_of_int votes_up /. float_of_int total in
    s.alpha <- (s.alpha -. 1.0) *. decay +. 1.0 +. success_rate;
    s.beta <- (s.beta -. 1.0) *. decay +. 1.0 +. (1.0 -. success_rate);
    s.alpha <- Float.max min_prior s.alpha;
    s.beta <- Float.max min_prior s.beta;
    s.total_votes_up <- s.total_votes_up + votes_up;
    s.total_votes_down <- s.total_votes_down + votes_down;
    s.updated_at <- Time_compat.now ()
  end

(** {1 Persistence} *)

let replace_stats_snapshot parsed =
  with_ts_rw (fun () ->
    clear_in_memory_stats_unlocked ();
    List.iter (fun s -> Hashtbl.replace stats_table s.name s) parsed;
    Hashtbl.length stats_table)
;;

let load_stats () =
  let path = stats_path () in
  if Fs_compat.file_exists path then begin
    try
      (* Boot-safe: malformed JSONL rows are dropped with diagnostics by
         Fs_compat; any remaining I/O/schema exception is logged below and does
         not abort server startup. *)
      let entries, malformed = Fs_compat.load_jsonl_diagnostics path in
      if malformed > 0 then
        Log.Thompson.warn "Dropped %d malformed stats line(s) from %s"
          malformed path;
      (* Parse outside the lock — [stats_of_json] is pure and avoids
         holding [ts_mu] across per-line work — then install the whole
         batch under one critical section. *)
      let parsed =
        List.filter_map (fun json ->
          match stats_of_json json with
          | Some s -> Some s
          | None ->
              Log.Thompson.warn "Failed to parse stats line: %s"
                (Yojson.Safe.to_string json);
              None
        ) entries
      in
      let count =
        replace_stats_snapshot parsed
      in
      Log.Metrics.debug "thompson sampling loaded stats for %d agents" count
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.Thompson.error "Error loading stats: %s"
        (Printexc.to_string e)
  end else begin
    let count = replace_stats_snapshot [] in
    Log.Metrics.debug "thompson sampling loaded stats for %d agents" count
  end

let stats_snapshot_for_persistence () =
  let decay = Env_config.AgentSelection.vote_decay_factor in
  with_ts_ro (fun () ->
    let by_name =
      Hashtbl.create (Hashtbl.length stats_table + Hashtbl.length pending_votes)
    in
    Hashtbl.iter
      (fun name stats -> Hashtbl.replace by_name name (copy_stats stats))
      stats_table;
    Hashtbl.iter
      (fun name (votes_up, votes_down) ->
         if votes_up + votes_down > 0 then begin
           let stats =
             match Hashtbl.find_opt by_name name with
             | Some stats -> stats
             | None ->
                 let stats = make_default_stats name in
                 Hashtbl.replace by_name name stats;
                 stats
           in
           apply_vote_counts ~decay stats ~votes_up ~votes_down
         end)
      pending_votes;
    Hashtbl.fold (fun _ stats acc -> stats :: acc) by_name [])

let save_stats () =
  let path = stats_path () in
  try
    (* Snapshot under the lock, then serialise the copies outside the
       critical section. Pending votes are overlaid on the snapshot so
       batched feedback reaches disk even though nothing drains
       [pending_votes] into the live table mid-process. *)
    let snapshot = stats_snapshot_for_persistence () in
    let buf = Buffer.create 4096 in
    List.iter
      (fun stats ->
         Buffer.add_string buf (Yojson.Safe.to_string (stats_to_json stats));
         Buffer.add_char buf '\n')
      snapshot;
    let content = Buffer.contents buf in
    let count = List.length snapshot in
    match Fs_compat.save_file_atomic path content with
    | Ok () ->
        Log.Metrics.debug "thompson sampling saved stats for %d agents" count
    | Error msg ->
        Log.Thompson.error "Error saving stats: %s" msg
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Log.Thompson.error "Error saving stats: %s"
      (Printexc.to_string e)

let persistence_configured () =
  with_ts_ro (fun () -> Option.is_some !base_path_ref)

let save_stats_if_configured () =
  if persistence_configured () then save_stats ()

(** {1 Feedback Updates} *)

let record_vote ~agent_name ~direction =
  with_ts_rw (fun () ->
    let (up, down) = Hashtbl.find_opt pending_votes agent_name
      |> Option.value ~default:(0, 0) in
    let (up', down') = match direction with
      | `Up -> (up + 1, down)
      | `Down -> (up, down + 1)
    in
    Hashtbl.replace pending_votes agent_name (up', down'));
  save_stats_if_configured ()

(* The record_* helpers below all mutate an [agent_stats] returned by
   [get_stats].  [get_stats] re-acquires [ts_mu] around the lookup, but
   returns the record to the caller which would then mutate fields
   lock-free — two racing fibers could read the same counter value and
   both write the same +1, silently dropping an update.  Wrap each
   mutation sequence in [with_ts_rw] so the read-modify-write stays
   atomic. *)
let record_action ~agent_name ~action =
  let s = get_stats agent_name in
  with_ts_rw (fun () ->
    (match action with
     | `Post -> s.posts_created <- s.posts_created + 1
     | `Comment -> s.comments_created <- s.comments_created + 1
     | `Skip -> s.skips <- s.skips + 1);
    s.updated_at <- Time_compat.now ());
  save_stats_if_configured ()

(** {1 Quality Signal Integration} *)

(** Post-verifier signal weights for Thompson Sampling prior updates.
    These are intentionally weaker than direct votes (1.0) because post-verifier
    verdicts are heuristic (corpus-free text checks), not human-validated.

    Rationale for specific values:
    - pass_alpha_boost (0.3): A pass is a weak positive signal — the content
      cleared automated checks, but that does not guarantee quality.
    - warn_beta_nudge (0.1): Warnings are informational, not definitive.
      Heavy penalty would over-rotate on stylistic issues.
    - fail_beta_penalty (0.5): Stronger than warn because the content was
      actively rejected, but still below 1.0 (human vote) because
      post-verifier false positives exist.

    These should be calibrated against actual agent performance data once
    Phase 0 instrumentation (RFC-0001) collects baseline metrics. *)
let quality_pass_alpha_boost = 0.3
let quality_warn_beta_nudge  = 0.1
let quality_fail_beta_penalty = 0.5

(** Record Post Verifier result into Thompson Sampling priors. *)
let record_quality_signal ~agent_name ~(verdict : quality_verdict) =
  let s = get_stats agent_name in
  with_ts_rw (fun () ->
    (match verdict with
     | Pass -> s.alpha <- s.alpha +. quality_pass_alpha_boost
     | Warn _ -> s.beta <- s.beta +. quality_warn_beta_nudge
     | Fail _ -> s.beta <- s.beta +. quality_fail_beta_penalty);
    s.alpha <- Float.max min_prior s.alpha;
    s.beta <- Float.max min_prior s.beta;
    s.updated_at <- Time_compat.now ());
  save_stats_if_configured ()
