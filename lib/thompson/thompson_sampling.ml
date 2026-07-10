(** Thompson Sampling — Agent Selection with Fairness Guarantees

    Implements agent selection using Thompson Sampling
    for quality-based selection with starvation prevention.

    Algorithm based on:
    - Devroye, "Non-Uniform Random Variate Generation" (Springer, 1986), Ch.9
    - [A Tutorial on Thompson Sampling](https://web.stanford.edu/~bvr/pubs/TS_Tutorial.pdf)
    - [Thompson Sampling with Fairness Constraints](https://arxiv.org/abs/2005.06725) *)

type quality_verdict =
  | Pass
  | Warn of string
  | Fail of string

(** {1 Types} *)

(* #9919 audit follow-up: Otel_metric_store counter for priority-trigger
   selections. Replaces a degenerate metric emit
   ([threshold=0.0, triggered=true] tautology). *)
let priority_trigger_selected_metric =
  "masc_thompson_priority_trigger_selected_total"

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

type selection_trigger =
  | Mentioned of string
  | ContentAlert of string
  | Scheduled
  | Starved
  | Thompson

type selection_result = {
  agent_name : string;
  trigger : selection_trigger;
  thompson_score : float;
  starvation_bonus : float;
  final_score : float;
  ticks_since_selection : int;
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

(** {1 Beta Distribution Sampling} *)

(** Sample from Gamma distribution using Marsaglia & Tsang's method.
    Reference: Devroye (1986), Ch.9 *)
let rec sample_gamma shape =
  if shape < 1.0 then
    (* For shape < 1, use shape+1 then adjust *)
    let g = sample_gamma (shape +. 1.0) in
    g *. (Random.float 1.0 ** (1.0 /. shape))
  else begin
    let d = shape -. (1.0 /. 3.0) in
    let c = 1.0 /. Float.sqrt (9.0 *. d) in
    let rec loop () =
      (* Generate standard normal using Box-Muller *)
      let u1 = Random.float 1.0 in
      let u2 = Random.float 1.0 in
      let z = Float.sqrt (-2.0 *. Float.log u1) *. Float.cos (2.0 *. Float.pi *. u2) in
      let v = (1.0 +. c *. z) in
      if v <= 0.0 then loop ()
      else begin
        let v = v *. v *. v in
        let u = Random.float 1.0 in
        (* Acceptance condition *)
        if Float.log u < 0.5 *. z *. z +. d -. d *. v +. d *. Float.log v then
          d *. v
        else
          loop ()
      end
    in
    loop ()
  end

(** Minimum prior value for numerical stability in Beta distribution sampling. *)
let min_prior = 0.1

(** Sample from Beta(alpha, beta) distribution using Gamma decomposition.
    Beta(a,b) = Gamma(a,1) / (Gamma(a,1) + Gamma(b,1)) *)
let sample_beta ~alpha ~beta =
  (* Clamp to minimum for numerical stability *)
  let alpha = Float.max min_prior alpha in
  let beta = Float.max min_prior beta in
  let x = sample_gamma alpha in
  let y = sample_gamma beta in
  if x +. y = 0.0 then 0.5  (* Degenerate case *)
  else x /. (x +. y)

(** {1 Starvation Bonus} *)

(** Logarithmic starvation bonus to prevent agent neglect.
    Uses ln(1+ticks) to avoid dominating Thompson score. *)
let starvation_bonus ~ticks =
  let coefficient = Env_config.AgentSelection.starvation_bonus_coefficient in
  coefficient *. Float.log (1.0 +. float_of_int ticks)

(** Calculate ticks since last selection based on timestamp *)
let ticks_since_selection ~stats ~tick_interval_s =
  let now = Time_compat.now () in
  let elapsed = now -. stats.last_selected_at in
  int_of_float (elapsed /. tick_interval_s)

let trigger_priority = function
  | Mentioned _ -> 3
  | ContentAlert _ -> 2
  | Starved -> 1
  | Scheduled | Thompson -> 0

let trigger_bypasses_health = function
  | Mentioned _ -> true
  | ContentAlert _ | Scheduled | Starved | Thompson -> false

(* [is_healthy] is injected by the caller of [select_with_feedback]
   (dependency inversion). Previously this called [Health.is_healthy]
   directly, coupling this module to the masc mega-library root. The
   caller now supplies the health predicate so this module stays a clean
   leaf. Required (not optional) — a permissive default would silently make
   every agent eligible if a caller forgot to wire health (CLAUDE.md
   "Unknown -> Permissive Default" anti-pattern). *)
let is_trigger_eligible ~is_healthy ~agent_name trigger =
  trigger_bypasses_health trigger || is_healthy ~agent_name

let normalized_subscore value =
  Float.max 0.0 (Float.min 0.999 value)

let priority_score ~trigger ~signal =
  float_of_int (trigger_priority trigger) +. normalized_subscore signal

let best_pending_triggers pending_triggers =
  let table = Hashtbl.create (List.length pending_triggers) in
  List.iteri
    (fun idx (name, trigger) ->
       match Hashtbl.find_opt table name with
       | Some (_, existing)
         when trigger_priority existing >= trigger_priority trigger ->
           ()
       | Some _ | None ->
           Hashtbl.replace table name (idx, trigger))
    pending_triggers;
  Hashtbl.fold
    (fun name (selected_idx, trigger) acc -> (selected_idx, name, trigger) :: acc)
    table []
  |> List.sort (fun (idx1, _, trigger1) (idx2, _, trigger2) ->
    match Int.compare (trigger_priority trigger2) (trigger_priority trigger1) with
    | 0 -> Int.compare idx1 idx2
    | n -> n
  )
  |> List.map (fun (_, name, trigger) -> (name, trigger))

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

let init_agent name =
  with_ts_rw (fun () ->
    if not (Hashtbl.mem stats_table name) then begin
      let s = make_default_stats name in
      Hashtbl.add stats_table name s
    end)

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
       critical section. Pending votes are overlaid on the snapshot so a
       graceful shutdown cannot lose batched feedback that has not reached
       [flush_pending_votes] yet. *)
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

let flush_pending_votes () =
  (* [ts_mu] is documented as protecting [pending_votes], but this
     function was the only access path that ignored the lock: callers
     of [record_vote] held it and could mutate [pending_votes] between
     [Hashtbl.iter] and [Hashtbl.clear], silently dropping those votes.
     Snapshot+clear the table atomically, release the lock, then apply
     the accumulated stat updates individually under the lock.  The
     two-step structure is required because [get_stats] re-acquires
     [ts_mu], and doing that inside a [Hashtbl.iter] held under the
     lock would either deadlock or skip the outer critical section. *)
  let decay = Env_config.AgentSelection.vote_decay_factor in
  let snapshot =
    with_ts_rw (fun () ->
      let xs =
        Hashtbl.fold (fun name counts acc -> (name, counts) :: acc)
          pending_votes []
      in
      Hashtbl.clear pending_votes;
      xs)
  in
  List.iter (fun (agent_name, (votes_up, votes_down)) ->
    let total = votes_up + votes_down in
    if total > 0 then begin
      let s = get_stats agent_name in
      with_ts_rw (fun () ->
        apply_vote_counts ~decay s ~votes_up ~votes_down)
    end
  ) snapshot;
  if snapshot <> [] then save_stats_if_configured ()

(* The record_* helpers below all mutate an [agent_stats] returned by
   [get_stats].  [get_stats] re-acquires [ts_mu] around the lookup, but
   returns the record to the caller which then mutated fields lock-free —
   so two fibers racing [record_selection ~agent_name:"X"] could both
   read [s.selections] at the same value and both write the same +1,
   silently dropping a selection.  Wrap each mutation sequence in
   [with_ts_rw] so the read-modify-write stays atomic. *)
let record_selection ~agent_name =
  let s = get_stats agent_name in
  with_ts_rw (fun () ->
    s.selections <- s.selections + 1;
    s.last_selected_at <- Time_compat.now ();
    s.updated_at <- Time_compat.now ());
  save_stats_if_configured ()

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

(** {1 Selection Algorithm} *)

(* [on_priority_selected] is an injected observability hook for the
   priority-trigger selection path. Previously this site called
   [Otel_metric_store.inc_counter] directly, coupling this module to the masc
   mega-library root. Defaulted to a no-op (observability, not behavior) so
   non-instrumented callers stay simple; an instrumented caller supplies the
   real Otel_metric_store increment. *)
let select_with_feedback
    ~is_healthy
    ?(on_priority_selected = fun ~agent_name:_ ~trigger_label:_ -> ())
    ~agents ~max_n ~pending_triggers ~tick_interval_s () =
  (* Drain any pending votes so Beta posteriors reflect recorded feedback
     before sampling. [record_vote] batches into [pending_votes], and
     without this flush the batched evidence never reaches [stats_table] —
     the sampler would read only the initial priors and votes are silently
     discarded over time. This sampling entry point is the natural "tick
     end" the .mli refers to. Safe to call under no lock: [flush] acquires
     [ts_mu] itself. *)
  flush_pending_votes ();
  (* Initialize stats for all agents *)
  List.iter init_agent agents;

  let selected = ref [] in
  (* Side-channel set for O(1) "already selected?" checks across the
     multi-phase selection loop.  [selected] (list) is still used for
     ordering and length checks; the Hashtbl mirrors only the names.

     Clamp the initial size: a negative [max_n] would raise
     [Invalid_argument] from [Hashtbl.create], and a pathologically
     large value would preallocate proportional buckets up-front.
     Bound by [List.length agents] since the loop cannot select more
     than that many names regardless of [max_n]. *)
  let initial_size = max 0 (min max_n (List.length agents)) in
  let selected_names : (string, unit) Hashtbl.t = Hashtbl.create initial_size in
  let is_selected name = Hashtbl.mem selected_names name in
  let mark_selected name = Hashtbl.replace selected_names name () in
  let add_selected result =
    selected := !selected @ [result];
    mark_selected result.agent_name
  in
  let priority_triggers = best_pending_triggers pending_triggers in

  (* 1. Priority triggers: Mentioned > ContentAlert *)
  List.iter (fun (name, trigger) ->
    match trigger with
    | Mentioned _ | ContentAlert _
      when List.length !selected < max_n
           && not (is_selected name)
           && is_trigger_eligible ~is_healthy ~agent_name:name trigger ->
        let s = get_stats name in
        let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
        let signal = starvation_bonus ~ticks in
        (* #9919 audit follow-up: the prior metric at this site was
           semi-degenerate — [threshold=0.0] and
           [triggered=true] were tautological (caller already filtered
           by eligibility).  The real useful observation is "a priority
           trigger was selected with [signal=X]"; expose it as a
           Otel_metric_store counter labelled by the trigger kind so operators
           can split mention-driven vs content-alert-driven selection
           rates. *)
        let trigger_label =
          match trigger with
          | Mentioned _ -> "mentioned"
          | ContentAlert _ -> "content_alert"
          | Scheduled | Starved | Thompson -> "other"
        in
        on_priority_selected ~agent_name:name ~trigger_label;
        add_selected {
          agent_name = name;
          trigger;
          thompson_score = 0.0;
          starvation_bonus = signal;
          final_score = priority_score ~trigger ~signal;
          ticks_since_selection = ticks;
        }
    | Mentioned _ | ContentAlert _ -> ()
    | Scheduled | Starved | Thompson -> ()
  ) priority_triggers;

  (* 2. Starvation rescue: force include agents who haven't been selected too long *)
  let max_starvation = Env_config.AgentSelection.max_starvation_ticks in
  let starved = List.filter_map (fun name ->
    if is_selected name then None
    else if not (is_trigger_eligible ~is_healthy ~agent_name:name Starved) then None
    else begin
      let s = get_stats name in
      let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
      if ticks >= max_starvation then
        Some (name, ticks)
      else
        None
    end
  ) agents in
  (* Sort by most starved first *)
  let starved_sorted = List.sort (fun (_, t1) (_, t2) -> Int.compare t2 t1) starved in
  List.iter (fun (name, ticks) ->
    if List.length !selected < max_n && not (is_selected name) then begin
      let signal = starvation_bonus ~ticks in
      add_selected {
        agent_name = name;
        trigger = Starved;
        thompson_score = 0.0;
        starvation_bonus = signal;
        final_score = priority_score ~trigger:Starved ~signal;
        ticks_since_selection = ticks;
      }
    end
  ) starved_sorted;

  (* 3. Thompson Sampling for remaining slots *)
  if List.length !selected < max_n then begin
    let thompson_weight = Env_config.AgentSelection.thompson_weight in
    let starvation_weight = 1.0 -. thompson_weight in

    let candidates = List.filter_map (fun name ->
      if is_selected name then None
      else if not (is_trigger_eligible ~is_healthy ~agent_name:name Thompson) then begin
        (* Unhealthy agents excluded from Thompson selection *)
        Log.Metrics.info "thompson sampling skipping %s (unhealthy)" name;
        None
      end
      else begin
        let s = get_stats name in
        let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
        let ts = sample_beta ~alpha:s.alpha ~beta:s.beta in
        let sb = starvation_bonus ~ticks in
        let final = priority_score ~trigger:Thompson
          ~signal:(thompson_weight *. ts +. starvation_weight *. sb) in
        Some {
          agent_name = name;
          trigger = Thompson;
          thompson_score = ts;
          starvation_bonus = sb;
          final_score = final;
          ticks_since_selection = ticks;
        }
      end
    ) agents in

    (* Sort by final score descending *)
    let sorted = List.sort (fun r1 r2 ->
      Float.compare r2.final_score r1.final_score
    ) candidates in

    (* Take remaining slots *)
    let remaining = max_n - List.length !selected in
    let rec take n = function
      | [] -> ()
      | _ when n <= 0 -> ()
      | r :: rest ->
          selected := r :: !selected;
          mark_selected r.agent_name;
          take (n - 1) rest
    in
    take remaining sorted
  end;

  (* Return sorted by final score *)
  List.stable_sort (fun r1 r2 -> Float.compare r2.final_score r1.final_score) !selected

(** {1 Monitoring} *)

(** Calculate selection entropy for balance monitoring.
    Higher entropy = more balanced selection across agents.
    Max = ln(n_agents) for uniform selection. *)
let selection_entropy () =
  let stats = get_all_stats () in
  if stats = [] then 0.0
  else begin
    let total_selections = List.fold_left (fun acc s -> acc + s.selections) 0 stats in
    if total_selections = 0 then 0.0
    else begin
      let total_f = float_of_int total_selections in
      List.fold_left (fun acc s ->
        if s.selections = 0 then acc
        else begin
          let p = float_of_int s.selections /. total_f in
          acc -. p *. Float.log p
        end
      ) 0.0 stats
    end
  end
