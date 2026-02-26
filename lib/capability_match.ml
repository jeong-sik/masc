(** Capability Match — Task-Agent Compatibility Scoring

    Computes compatibility between tasks and agents based on
    keyword overlap between task content and agent traits/interests.

    Used to improve task assignment from first-come-first-served
    to capability-aware matching (COALESCE pattern).

    Scoring formula:
      score = trait_overlap * 0.4 + interest_overlap * 0.4 + capability_match * 0.2

    @see "Orchestrating Human-AI Teams" — capability-based assignment
    @since 2.60.0 *)

(** Agent capabilities for matching.
    Extracted from GraphQL agent fields or Agent_identity.t *)
type agent_profile = {
  name: string;
  traits: string list;         (** Personality traits: ["analytical"; "creative"] *)
  interests: string list;      (** Domain interests: ["security"; "frontend"] *)
  capabilities: string list;   (** Technical capabilities: ["code-review"; "testing"] *)
  model: string option;        (** LLM model, if relevant *)
  activity_level: float;       (** 0.0-1.0, higher = more active *)
  role: Agent_identity.role;   (** Agent's role for task filtering *)
} [@@deriving show, eq]

(** Task requirements extracted from task content *)
type task_profile = {
  task_id: string;
  title: string;
  description: string;
  priority: int;
  keywords: string list;       (** Auto-extracted from title + description *)
  required_role: Agent_identity.role;  (** Role required to claim this task *)
} [@@deriving show, eq]

(** Match result between one agent and one task *)
type match_score = {
  agent_name: string;
  task_id: string;
  trait_score: float;       (** 0.0-1.0: how well traits match task keywords *)
  interest_score: float;    (** 0.0-1.0: how well interests match *)
  capability_score: float;  (** 0.0-1.0: direct capability match *)
  total_score: float;       (** Weighted combination *)
} [@@deriving show, eq]

(* ---------- Keyword Extraction ---------- *)

(** Common stop words to exclude from keyword extraction *)
let stop_words = [
  "the"; "a"; "an"; "is"; "are"; "was"; "were"; "be"; "been";
  "have"; "has"; "had"; "do"; "does"; "did"; "will"; "would";
  "could"; "should"; "may"; "might"; "can"; "shall";
  "in"; "on"; "at"; "to"; "for"; "with"; "by"; "from"; "of";
  "and"; "or"; "but"; "not"; "no"; "if"; "then"; "else";
  "this"; "that"; "these"; "those"; "it"; "its";
  "task"; "add"; "update"; "fix"; "implement"; "create"; "new";
]

(** Normalize a word: lowercase, strip non-alphanumeric *)
let normalize_word w =
  let buf = Buffer.create (String.length w) in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then
      Buffer.add_char buf c
    else if c >= 'A' && c <= 'Z' then
      Buffer.add_char buf (Char.chr (Char.code c + 32))
  ) w;
  Buffer.contents buf

(** Extract keywords from text: split, normalize, filter stop words and short words *)
let extract_keywords (text : string) : string list =
  text
  |> String.split_on_char ' '
  |> List.concat_map (String.split_on_char '-')
  |> List.concat_map (String.split_on_char '_')
  |> List.map normalize_word
  |> List.filter (fun w -> String.length w > 2)
  |> List.filter (fun w -> not (List.mem w stop_words))
  |> List.sort_uniq String.compare

(** Build a task profile with auto-extracted keywords *)
let task_profile_of_task (task : Types.task) : task_profile =
  let text = task.title ^ " " ^ task.description in
  {
    task_id = task.id;
    title = task.title;
    description = task.description;
    priority = task.priority;
    keywords = extract_keywords text;
    required_role = task.required_role;
  }

(** Build an agent profile from GraphQL agent data (JSON) *)
let agent_profile_of_json (json : Yojson.Safe.t) : agent_profile option =
  let module U = Yojson.Safe.Util in
  try
    let name = json |> U.member "name" |> U.to_string in
    let to_string_list j =
      match j with
      | `List vs -> List.filter_map (fun v -> try Some (U.to_string v) with _ -> None) vs
      | `String s -> String.split_on_char ',' s |> List.map String.trim
      | _ -> []
    in
    let role = match json |> U.member "role" |> U.to_string_option with
      | Some s -> Agent_identity.role_of_string s
      | None -> Agent_identity.Unassigned
    in
    Some {
      name;
      traits = json |> U.member "traits" |> to_string_list |> List.map normalize_word;
      interests = json |> U.member "interests" |> to_string_list |> List.map normalize_word;
      capabilities = [];
      model = json |> U.member "model" |> U.to_string_option;
      activity_level =
        (try json |> U.member "activityLevel" |> U.to_float with _ -> 0.5);
      role;
    }
  with _ -> None

(** Build an agent profile from Agent_identity.t *)
let agent_profile_of_identity (id : Agent_identity.t) : agent_profile =
  {
    name = id.agent_name;
    traits = [];
    interests = [];
    capabilities = List.map normalize_word id.capabilities;
    model = None;
    activity_level = 0.5;
    role = Agent_identity.get_role id;
  }

(* ---------- Scoring ---------- *)

(** Compute keyword overlap between two lists.
    Returns 0.0-1.0: |intersection| / |reference| *)
let keyword_overlap (reference : string list) (candidate : string list) : float =
  if reference = [] then 0.0
  else
    let ref_set = reference in
    let matching = List.filter (fun kw ->
      List.exists (fun r ->
        (* Exact match or substring containment *)
        r = kw ||
        (String.length r >= 3 && String.length kw >= 3 &&
         let shorter = if String.length r < String.length kw then r else kw in
         let longer = if String.length r >= String.length kw then r else kw in
         let s_len = String.length shorter in
         let l_len = String.length longer in
         if s_len > l_len then false
         else
           let rec check i =
             if i > l_len - s_len then false
             else if String.sub longer i s_len = shorter then true
             else check (i + 1)
           in
           check 0)
      ) ref_set
    ) candidate in
    float_of_int (List.length matching) /. float_of_int (List.length reference)

(** Compute match score between an agent and a task.
    When the task has a required_role, agents without a matching role
    receive a total_score of 0.0 (filtered out). *)
let score (agent : agent_profile) (task : task_profile) : match_score =
  let role_ok = Agent_identity.role_satisfies
    ~required:task.required_role ~agent_role:agent.role in
  let trait_score = keyword_overlap task.keywords agent.traits in
  let interest_score = keyword_overlap task.keywords agent.interests in
  let capability_score = keyword_overlap task.keywords agent.capabilities in
  let base_score =
    trait_score *. 0.4
    +. interest_score *. 0.4
    +. capability_score *. 0.2
  in
  let total_score = if role_ok then base_score else 0.0 in
  {
    agent_name = agent.name;
    task_id = task.task_id;
    trait_score;
    interest_score;
    capability_score;
    total_score;
  }

(** Rank agents for a given task. Returns agents sorted by compatibility (best first). *)
let rank_agents_for_task (agents : agent_profile list) (task : task_profile)
    : match_score list =
  agents
  |> List.map (fun agent -> score agent task)
  |> List.sort (fun a b -> compare b.total_score a.total_score)

(** Rank tasks for a given agent. Returns tasks sorted by compatibility (best first). *)
let rank_tasks_for_agent (agent : agent_profile) (tasks : task_profile list)
    : match_score list =
  tasks
  |> List.map (fun task -> score agent task)
  |> List.sort (fun a b -> compare b.total_score a.total_score)

(** Find the best agent for a task, or None if no agents have any match *)
let best_agent_for_task ?(min_score = 0.0) (agents : agent_profile list) (task : task_profile)
    : match_score option =
  match rank_agents_for_task agents task with
  | best :: _ when best.total_score > min_score -> Some best
  | _ -> None

(** Suggest task for an agent (from available todo tasks).
    Returns the best-matching task or None. *)
let suggest_task_for_agent ?(min_score = 0.0) (agent : agent_profile) (tasks : task_profile list)
    : match_score option =
  match rank_tasks_for_agent agent tasks with
  | best :: _ when best.total_score > min_score -> Some best
  | _ -> None

(* ---------- JSON Serialization ---------- *)

let match_score_to_json (m : match_score) : Yojson.Safe.t =
  `Assoc [
    ("agentName", `String m.agent_name);
    ("taskId", `String m.task_id);
    ("traitScore", `Float m.trait_score);
    ("interestScore", `Float m.interest_score);
    ("capabilityScore", `Float m.capability_score);
    ("totalScore", `Float m.total_score);
  ]

let ranking_to_json (scores : match_score list) : Yojson.Safe.t =
  `List (List.map match_score_to_json scores)
