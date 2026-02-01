(** Balance policy for agent fairness in MASC system *)

(** Agent participation statistics *)
type agent_stats = {
  wins : int;
  participations : int;
  last_win : float option;  (** Unix timestamp of last win *)
}

(** Balance enforcement actions *)
type balance_action =
  | ForcedRotation       (** Force rotation due to dominance *)
  | MandatoryParticipation  (** Require participation from inactive agent *)
  | Clear                (** No action needed *)

(** Configuration constants *)
let max_consecutive_wins = 3
let min_participation = 0.2

(** Create empty agent stats *)
let empty_stats () : agent_stats =
  { wins = 0; participations = 0; last_win = None }

(** Check if an agent is dominating (too many consecutive wins) *)
let check_dominance ~(agent_stats : agent_stats) ~(total_rounds : int) : bool =
  if total_rounds < max_consecutive_wins then false
  else agent_stats.wins >= max_consecutive_wins

(** Calculate participation rate for an agent *)
let get_participation_rate ~(agent_stats : agent_stats) ~(total_rounds : int) : float =
  if total_rounds = 0 then 0.0
  else Float.of_int agent_stats.participations /. Float.of_int total_rounds

(** Determine the balance action needed for an agent *)
let determine_action
    ~(agent_stats : agent_stats)
    ~(total_rounds : int)
    ~(is_winner : bool)
  : balance_action =
  (* Check dominance - if winning too much, force rotation *)
  if is_winner && check_dominance ~agent_stats ~total_rounds then
    ForcedRotation
  (* Check participation - if not participating enough, mandate involvement *)
  else if get_participation_rate ~agent_stats ~total_rounds < min_participation 
          && total_rounds >= 5 then
    MandatoryParticipation
  else
    Clear

(** Apply rotation policy - select next agent from candidates
    Returns the agent_id that should participate next *)
let apply_rotation
    ~(stats_table : (string, agent_stats) Hashtbl.t)
    ~(candidates : string list)
    ~(current_winner : string option)
  : string option =
  match candidates with
  | [] -> None
  | _ ->
    (* Exclude current winner if rotation is forced *)
    let eligible = match current_winner with
      | Some winner -> List.filter (fun id -> id <> winner) candidates
      | None -> candidates
    in
    (* Sort by least wins, then by longest time since last win *)
    let sorted = List.sort (fun a b ->
      let stats_a = Hashtbl.find_opt stats_table a |> Option.value ~default:(empty_stats ()) in
      let stats_b = Hashtbl.find_opt stats_table b |> Option.value ~default:(empty_stats ()) in
      (* Primary: fewer wins first *)
      let win_cmp = Int.compare stats_a.wins stats_b.wins in
      if win_cmp <> 0 then win_cmp
      else
        (* Secondary: longer time since last win first (None = never won = highest priority) *)
        match stats_a.last_win, stats_b.last_win with
        | None, None -> 0
        | None, Some _ -> -1  (* a never won, prioritize a *)
        | Some _, None -> 1   (* b never won, prioritize b *)
        | Some ta, Some tb -> Float.compare ta tb  (* earlier last_win = higher priority *)
    ) eligible in
    List.nth_opt sorted 0

(** Protect minority opinions - ensure underrepresented agents get voice
    Returns list of agent_ids that should be given opportunity to contribute *)
let protect_minority
    ~(stats_table : (string, agent_stats) Hashtbl.t)
    ~(all_agents : string list)
    ~(total_rounds : int)
  : string list =
  if total_rounds < 5 then []  (* Not enough data yet *)
  else
    List.filter (fun agent_id ->
      let stats = Hashtbl.find_opt stats_table agent_id 
                  |> Option.value ~default:(empty_stats ()) in
      get_participation_rate ~agent_stats:stats ~total_rounds < min_participation
    ) all_agents

(** Record a win for an agent *)
let record_win ~(stats_table : (string, agent_stats) Hashtbl.t) ~(agent_id : string) : unit =
  let current = Hashtbl.find_opt stats_table agent_id 
                |> Option.value ~default:(empty_stats ()) in
  let updated = {
    wins = current.wins + 1;
    participations = current.participations;
    last_win = Some (Unix.gettimeofday ());
  } in
  Hashtbl.replace stats_table agent_id updated

(** Record participation (without win) for an agent *)
let record_participation ~(stats_table : (string, agent_stats) Hashtbl.t) ~(agent_id : string) : unit =
  let current = Hashtbl.find_opt stats_table agent_id 
                |> Option.value ~default:(empty_stats ()) in
  let updated = { current with participations = current.participations + 1 } in
  Hashtbl.replace stats_table agent_id updated

(** Reset all stats (e.g., for new session) *)
let reset_all ~(stats_table : (string, agent_stats) Hashtbl.t) : unit =
  Hashtbl.clear stats_table

(** Get balance summary for monitoring *)
let get_summary
    ~(stats_table : (string, agent_stats) Hashtbl.t)
    ~(total_rounds : int)
  : (string * float * int * balance_action) list =
  Hashtbl.fold (fun agent_id stats acc ->
    let rate = get_participation_rate ~agent_stats:stats ~total_rounds in
    let action = determine_action ~agent_stats:stats ~total_rounds ~is_winner:false in
    (agent_id, rate, stats.wins, action) :: acc
  ) stats_table []
