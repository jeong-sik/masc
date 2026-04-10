(** Thompson Sampling — Agent Selection with Fairness Guarantees

    Implements agent selection using Thompson Sampling
    for quality-based selection with starvation prevention.

    Algorithm based on:
    - Devroye, "Non-Uniform Random Variate Generation" (Springer, 1986), Ch.9
    - [A Tutorial on Thompson Sampling](https://web.stanford.edu/~bvr/pubs/TS_Tutorial.pdf)
    - [Thompson Sampling with Fairness Constraints](https://arxiv.org/abs/2005.06725) *)

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

(** Set base path for stats storage. Call during server init. *)
let set_base_path path =
  with_ts_rw (fun () -> base_path_ref := Some path)

(** Stats file path — uses cluster base_path, not execution directory *)
let stats_path () =
  let base = match !base_path_ref with
    | Some p -> p
    | None ->
        (* Fallback: try to get from environment or use current dir *)
        Env_config_core.base_path ()
  in
  let masc_dir = Filename.concat base ".masc" in
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

let is_trigger_eligible ~agent_name trigger =
  trigger_bypasses_health trigger || Agent_health.is_healthy ~agent_name

let normalized_subscore value =
  Float.max 0.0 (Float.min 0.999 value)

let priority_score ~trigger ~signal =
  float_of_int (trigger_priority trigger) +. normalized_subscore signal

let best_pending_triggers pending_triggers =
  let table : (string, int * selection_trigger) Hashtbl.t = Hashtbl.create 16 in
  List.iteri (fun idx (name, trigger) ->
    match Hashtbl.find_opt table name with
    | Some (_, existing)
      when trigger_priority existing >= trigger_priority trigger -> ()
    | Some _ ->
        Hashtbl.replace table name (idx, trigger)
    | None ->
        Hashtbl.add table name (idx, trigger)
  ) pending_triggers;
  Hashtbl.fold (fun name (first_idx, trigger) acc ->
    (first_idx, name, trigger) :: acc
  ) table []
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

let stats_of_json (json : Yojson.Safe.t) : agent_stats option =
  let open Yojson.Safe.Util in
  try
    let name = json |> member "name" |> to_string in
    let alpha = json |> member "alpha" |> to_float in
    let beta = json |> member "beta" |> to_float in
    let selections = json |> member "selections" |> to_int in
    let last_selected_at = json |> member "last_selected_at" |> to_float in
    let total_votes_up = json |> member "total_votes_up" |> to_int in
    let total_votes_down = json |> member "total_votes_down" |> to_int in
    let posts_created = json |> member "posts_created" |> to_int_option |> Option.value ~default:0 in
    let comments_created = json |> member "comments_created" |> to_int_option |> Option.value ~default:0 in
    let skips = json |> member "skips" |> to_int_option |> Option.value ~default:0 in
    let updated_at = json |> member "updated_at" |> to_float in
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
  with Yojson.Safe.Util.Type_error _ -> None

(** {1 Persistence} *)

let load_stats () =
  let path = stats_path () in
  if Fs_compat.file_exists path then begin
    try
      let entries = Fs_compat.load_jsonl path in
      List.iter (fun json ->
        match stats_of_json json with
        | Some s ->
            Hashtbl.replace stats_table s.name s
        | None ->
            Log.Thompson.warn "Failed to parse stats line: %s"
              (Yojson.Safe.to_string json)
      ) entries;
      Log.Metrics.debug "thompson sampling loaded stats for %d agents"
        (Hashtbl.length stats_table)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e ->
      Log.Thompson.error "Error loading stats: %s"
        (Printexc.to_string e)
  end

let save_stats () =
  let path = stats_path () in
  try
    let content =
      Hashtbl.fold (fun _ s acc ->
        acc ^ Yojson.Safe.to_string (stats_to_json s) ^ "\n"
      ) stats_table ""
    in
    Fs_compat.save_file path content;
    Log.Metrics.debug "thompson sampling saved stats for %d agents"
      (Hashtbl.length stats_table)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Log.Thompson.error "Error saving stats: %s"
      (Printexc.to_string e)

(** {1 Feedback Updates} *)

let record_vote ~agent_name ~direction =
  with_ts_rw (fun () ->
    let (up, down) = Hashtbl.find_opt pending_votes agent_name
      |> Option.value ~default:(0, 0) in
    let (up', down') = match direction with
      | `Up -> (up + 1, down)
      | `Down -> (up, down + 1)
    in
    Hashtbl.replace pending_votes agent_name (up', down'))

let flush_pending_votes () =
  let decay = Env_config.AgentSelection.vote_decay_factor in
  Hashtbl.iter (fun agent_name (votes_up, votes_down) ->
    let total = votes_up + votes_down in
    if total > 0 then begin
      let s = get_stats agent_name in
      let success_rate = float_of_int votes_up /. float_of_int total in
      (* Apply decay to existing priors, then add new evidence *)
      s.alpha <- (s.alpha -. 1.0) *. decay +. 1.0 +. success_rate;
      s.beta <- (s.beta -. 1.0) *. decay +. 1.0 +. (1.0 -. success_rate);
      (* Clamp to minimum *)
      s.alpha <- Float.max min_prior s.alpha;
      s.beta <- Float.max min_prior s.beta;
      (* Update totals *)
      s.total_votes_up <- s.total_votes_up + votes_up;
      s.total_votes_down <- s.total_votes_down + votes_down;
      s.updated_at <- Time_compat.now ()
    end
  ) pending_votes;
  Hashtbl.clear pending_votes

let record_selection ~agent_name =
  let s = get_stats agent_name in
  s.selections <- s.selections + 1;
  s.last_selected_at <- Time_compat.now ();
  s.updated_at <- Time_compat.now ()

let record_action ~agent_name ~action =
  let s = get_stats agent_name in
  (match action with
   | `Post -> s.posts_created <- s.posts_created + 1
   | `Comment -> s.comments_created <- s.comments_created + 1
   | `Skip -> s.skips <- s.skips + 1);
  s.updated_at <- Time_compat.now ()

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
    Phase 0 instrumentation (RFC-0001) collects baseline metrics.
    TODO(RFC-0001): Register in Runtime_params for runtime tuning. *)
let quality_pass_alpha_boost = 0.3
let quality_warn_beta_nudge  = 0.1
let quality_fail_beta_penalty = 0.5

(** Guard penalty β nudge: same magnitude as quality_fail.
    Configurable via MASC_GUARD_PENALTY_BETA for B-SIM calibration.
    Default 0.5 is a conservative pre-calibration estimate. *)
let guard_penalty_beta_nudge =
  Env_config_core.get_float ~default:0.5 "MASC_GUARD_PENALTY_BETA"

(** Record a guard penalty (Guardrail_stop) into Thompson β.
    Phase B1: Guard → Thompson bridge.
    Penalty cap (1/cycle) is enforced by the caller. *)
let record_guard_penalty ~agent_name =
  let s = get_stats agent_name in
  s.beta <- s.beta +. guard_penalty_beta_nudge;
  s.beta <- Float.max min_prior s.beta;
  s.updated_at <- Time_compat.now ()

(** Record Post Verifier result into Thompson Sampling priors. *)
let record_quality_signal ~agent_name ~(verdict : Post_verifier.verdict) =
  let s = get_stats agent_name in
  (match verdict with
   | Post_verifier.Pass -> s.alpha <- s.alpha +. quality_pass_alpha_boost
   | Post_verifier.Warn _ -> s.beta <- s.beta +. quality_warn_beta_nudge
   | Post_verifier.Fail _ -> s.beta <- s.beta +. quality_fail_beta_penalty);
  s.alpha <- Float.max min_prior s.alpha;
  s.beta <- Float.max min_prior s.beta;
  s.updated_at <- Time_compat.now ()

(** {1 Selection Algorithm} *)

let select_with_feedback ~agents ~max_n ~pending_triggers ~tick_interval_s =
  (* Initialize stats for all agents *)
  List.iter init_agent agents;

  let selected = ref [] in
  let selected_names = ref [] in
  let add_selected result =
    selected := !selected @ [result];
    selected_names := result.agent_name :: !selected_names
  in
  let priority_triggers = best_pending_triggers pending_triggers in

  (* 1. Priority triggers: Mentioned > ContentAlert *)
  List.iter (fun (name, trigger) ->
    match trigger with
    | Mentioned _ | ContentAlert _
      when List.length !selected < max_n
           && not (List.mem name !selected_names)
           && is_trigger_eligible ~agent_name:name trigger ->
        let s = get_stats name in
        let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
        let signal = starvation_bonus ~ticks in
        (* RFC-0001 Gate A: record thompson selection observation *)
        Heuristic_metrics.record {
          module_name = "thompson_sampling"; site = "priority_trigger";
          raw_value = signal; threshold = 0.0;
          triggered = true;
          provenance = Thompson "starvation_bonus";
          timestamp = Unix.gettimeofday ();
        };
        add_selected {
          agent_name = name;
          trigger;
          thompson_score = 0.0;
          starvation_bonus = signal;
          final_score = priority_score ~trigger ~signal;
          ticks_since_selection = ticks;
        }
    | _ -> ()
  ) priority_triggers;

  (* 2. Starvation rescue: force include agents who haven't been selected too long *)
  let max_starvation = Env_config.AgentSelection.max_starvation_ticks in
  let starved = List.filter_map (fun name ->
    if List.mem name !selected_names then None
    else if not (is_trigger_eligible ~agent_name:name Starved) then None
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
    if List.length !selected < max_n && not (List.mem name !selected_names) then begin
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
      if List.mem name !selected_names then None
      else if not (is_trigger_eligible ~agent_name:name Thompson) then begin
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
          selected_names := r.agent_name :: !selected_names;
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
  if List.length stats = 0 then 0.0
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
