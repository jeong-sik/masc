(** Lodge Selection — Thompson Sampling with Fairness Guarantees

    Implements agent selection for Lodge Heartbeat using Thompson Sampling
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

(** Stats file path *)
let stats_path () =
  let masc_dir = ".masc" in
  if not (Sys.file_exists masc_dir) then
    Unix.mkdir masc_dir 0o755;
  Filename.concat masc_dir "lodge_stats.jsonl"

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

(** Sample from Beta(alpha, beta) distribution using Gamma decomposition.
    Beta(a,b) = Gamma(a,1) / (Gamma(a,1) + Gamma(b,1)) *)
let sample_beta ~alpha ~beta =
  (* Clamp to minimum 0.1 for numerical stability *)
  let alpha = Float.max 0.1 alpha in
  let beta = Float.max 0.1 beta in
  let x = sample_gamma alpha in
  let y = sample_gamma beta in
  if x +. y = 0.0 then 0.5  (* Degenerate case *)
  else x /. (x +. y)

(** {1 Starvation Bonus} *)

(** Logarithmic starvation bonus to prevent agent neglect.
    Uses ln(1+ticks) to avoid dominating Thompson score. *)
let starvation_bonus ~ticks =
  let coefficient = Env_config.LodgeSelection.starvation_bonus_coefficient in
  coefficient *. Float.log (1.0 +. float_of_int ticks)

(** Calculate ticks since last selection based on timestamp *)
let ticks_since_selection ~stats ~tick_interval_s =
  let now = Time_compat.now () in
  let elapsed = now -. stats.last_selected_at in
  int_of_float (elapsed /. tick_interval_s)

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
  match Hashtbl.find_opt stats_table name with
  | Some s -> s
  | None ->
      let s = make_default_stats name in
      Hashtbl.add stats_table name s;
      s

let get_all_stats () =
  Hashtbl.fold (fun _ v acc -> v :: acc) stats_table []

let init_agent name =
  if not (Hashtbl.mem stats_table name) then begin
    let s = make_default_stats name in
    Hashtbl.add stats_table name s
  end

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
      alpha = Float.max 0.1 alpha;
      beta = Float.max 0.1 beta;
      selections;
      last_selected_at;
      total_votes_up;
      total_votes_down;
      posts_created;
      comments_created;
      skips;
      updated_at;
    }
  with _ -> None

(** {1 Persistence} *)

let load_stats () =
  let path = stats_path () in
  if Sys.file_exists path then begin
    try
      let ic = open_in path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        try
          while true do
            let line = input_line ic in
            if String.length line > 0 then begin
              let json = Yojson.Safe.from_string line in
              match stats_of_json json with
              | Some s ->
                  Hashtbl.replace stats_table s.name s
              | None ->
                  Printf.eprintf "[lodge_selection] Failed to parse stats line\n%!"
            end
          done
        with End_of_file -> ()
      );
      Printf.printf "[lodge_selection] Loaded stats for %d agents\n%!"
        (Hashtbl.length stats_table)
    with e ->
      Printf.eprintf "[lodge_selection] Error loading stats: %s\n%!"
        (Printexc.to_string e)
  end

let save_stats () =
  let path = stats_path () in
  try
    let oc = open_out path in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
      Hashtbl.iter (fun _ s ->
        let json = stats_to_json s in
        output_string oc (Yojson.Safe.to_string json ^ "\n")
      ) stats_table
    );
    Printf.printf "[lodge_selection] Saved stats for %d agents\n%!"
      (Hashtbl.length stats_table)
  with e ->
    Printf.eprintf "[lodge_selection] Error saving stats: %s\n%!"
      (Printexc.to_string e)

(** {1 Feedback Updates} *)

let record_vote ~agent_name ~direction =
  let (up, down) = Hashtbl.find_opt pending_votes agent_name
    |> Option.value ~default:(0, 0) in
  let (up', down') = match direction with
    | `Up -> (up + 1, down)
    | `Down -> (up, down + 1)
  in
  Hashtbl.replace pending_votes agent_name (up', down')

let flush_pending_votes () =
  let decay = Env_config.LodgeSelection.vote_decay_factor in
  Hashtbl.iter (fun agent_name (votes_up, votes_down) ->
    let total = votes_up + votes_down in
    if total > 0 then begin
      let s = get_stats agent_name in
      let success_rate = float_of_int votes_up /. float_of_int total in
      (* Apply decay to existing priors, then add new evidence *)
      s.alpha <- (s.alpha -. 1.0) *. decay +. 1.0 +. success_rate;
      s.beta <- (s.beta -. 1.0) *. decay +. 1.0 +. (1.0 -. success_rate);
      (* Clamp to minimum *)
      s.alpha <- Float.max 0.1 s.alpha;
      s.beta <- Float.max 0.1 s.beta;
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

(** {1 Selection Algorithm} *)

let select_with_feedback ~agents ~max_n ~pending_triggers ~tick_interval_s =
  (* Initialize stats for all agents *)
  List.iter init_agent agents;

  let selected = ref [] in
  let selected_names = ref [] in

  (* 1. Priority triggers: Mentioned (highest) *)
  List.iter (fun (name, trigger) ->
    match trigger with
    | Mentioned _ when List.length !selected < max_n
                    && not (List.mem name !selected_names) ->
        let s = get_stats name in
        let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
        selected := {
          agent_name = name;
          trigger;
          thompson_score = 0.0;
          starvation_bonus = 0.0;
          final_score = 1.0;  (* Max priority *)
          ticks_since_selection = ticks;
        } :: !selected;
        selected_names := name :: !selected_names
    | _ -> ()
  ) pending_triggers;

  (* 2. Priority triggers: ContentAlert *)
  List.iter (fun (name, trigger) ->
    match trigger with
    | ContentAlert _ when List.length !selected < max_n
                       && not (List.mem name !selected_names) ->
        let s = get_stats name in
        let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
        selected := {
          agent_name = name;
          trigger;
          thompson_score = 0.0;
          starvation_bonus = 0.0;
          final_score = 0.9;  (* High priority *)
          ticks_since_selection = ticks;
        } :: !selected;
        selected_names := name :: !selected_names
    | _ -> ()
  ) pending_triggers;

  (* 3. Starvation rescue: force include agents who haven't been selected too long *)
  let max_starvation = Env_config.LodgeSelection.max_starvation_ticks in
  let starved = List.filter_map (fun name ->
    if List.mem name !selected_names then None
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
      selected := {
        agent_name = name;
        trigger = Starved;
        thompson_score = 0.0;
        starvation_bonus = starvation_bonus ~ticks;
        final_score = 0.85;  (* Below ContentAlert but guaranteed *)
        ticks_since_selection = ticks;
      } :: !selected;
      selected_names := name :: !selected_names
    end
  ) starved_sorted;

  (* 4. Thompson Sampling for remaining slots *)
  if List.length !selected < max_n then begin
    let thompson_weight = Env_config.LodgeSelection.thompson_weight in
    let starvation_weight = 1.0 -. thompson_weight in

    let candidates = List.filter_map (fun name ->
      if List.mem name !selected_names then None
      else begin
        let s = get_stats name in
        let ticks = ticks_since_selection ~stats:s ~tick_interval_s in
        let ts = sample_beta ~alpha:s.alpha ~beta:s.beta in
        let sb = starvation_bonus ~ticks in
        let final = thompson_weight *. ts +. starvation_weight *. sb in
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
  List.sort (fun r1 r2 -> Float.compare r2.final_score r1.final_score) !selected

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
