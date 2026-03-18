(** Capability Match — Task-Agent Compatibility Scoring

    Computes compatibility between tasks and agents using keyword
    overlap (heuristic) or LLM-based semantic scoring (llm/hybrid).

    Used to improve task assignment from first-come-first-served
    to capability-aware matching (COALESCE pattern).

    Keyword scoring formula:
      score = trait_overlap * 0.4 + interest_overlap * 0.4 + capability_match * 0.2

    LLM scoring: Prompts an LLM to rate agent-task fit as 0.0-1.0,
    capturing semantic similarity that keyword overlap misses
    (e.g. "security" ↔ "cybersecurity", "frontend" ↔ "UI").

    Mode selection via MASC_CAPABILITY_MATCH_MODE:
      - keyword: existing heuristic, 0-latency
      - llm: LLM-only scoring
      - hybrid (default): LLM with keyword fallback on failure

    @see "Orchestrating Human-AI Teams" — capability-based assignment
    @see arXiv 2601.04748 — semantic confusability in agent routing
    @since 2.60.0
    @since 2.65.0 — LLM/hybrid scoring modes *)

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
  mode: string;             (** Active scoring mode *)
  provenance: string;       (** judgment | derived | fallback *)
} [@@deriving show, eq]

(* ---------- Match Mode ---------- *)

(** Scoring mode: keyword heuristic, LLM semantic, or hybrid. *)
type match_mode = Keyword | Llm | Hybrid

let get_match_mode () : match_mode =
  match Sys.getenv_opt "MASC_CAPABILITY_MATCH_MODE" with
  | Some "llm" -> Llm
  | Some "keyword" -> Keyword
  | _ -> Hybrid

let match_mode_to_string = function
  | Keyword -> "keyword"
  | Llm -> "llm"
  | Hybrid -> "hybrid"

type score_provenance =
  | Judgment
  | Derived
  | Fallback

let score_provenance_to_string = function
  | Judgment -> "judgment"
  | Derived -> "derived"
  | Fallback -> "fallback"

let make_match_score ~mode ~provenance ~agent_name ~task_id
    ~trait_score ~interest_score ~capability_score ~total_score =
  {
    agent_name;
    task_id;
    trait_score;
    interest_score;
    capability_score;
    total_score;
    mode = match_mode_to_string mode;
    provenance = score_provenance_to_string provenance;
  }

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
      | `List vs -> List.filter_map (fun v -> try Some (U.to_string v) with Yojson.Safe.Util.Type_error _ -> None) vs
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
        (try json |> U.member "activityLevel" |> U.to_float with Yojson.Safe.Util.Type_error _ -> 0.5);
      role;
    }
  with Yojson.Safe.Util.Type_error _ -> None

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

(* ---------- LLM Scoring ---------- *)

(** Build the LLM prompt for agent-task compatibility scoring. *)
let build_scoring_prompt (agent : agent_profile) (task : task_profile) : string =
  let traits_str = match agent.traits with
    | [] -> "none"
    | ts -> String.concat ", " ts
  in
  let interests_str = match agent.interests with
    | [] -> "none"
    | is -> String.concat ", " is
  in
  let caps_str = match agent.capabilities with
    | [] -> "none"
    | cs -> String.concat ", " cs
  in
  Printf.sprintf
{|Rate how well this agent matches the task. Reply with ONLY a decimal number between 0.0 and 1.0.

Agent: %s
  Traits: %s
  Interests: %s
  Capabilities: %s

Task: %s
  Description: %s

Score (0.0 = no match, 1.0 = perfect match):|}
    agent.name traits_str interests_str caps_str
    task.title task.description

(** Parse a float score from LLM response text.
    Extracts the first decimal number found in the response. *)
let parse_llm_score (text : string) : float option =
  let s = String.trim text in
  (* Try direct float_of_string first *)
  match float_of_string_opt s with
  | Some f when f >= 0.0 && f <= 1.0 -> Some f
  | _ ->
      (* Scan for first decimal pattern like "0.85" in the response *)
      let len = String.length s in
      let rec scan i =
        if i >= len then None
        else
          let c = s.[i] in
          if (c >= '0' && c <= '9') || c = '.' then
            (* Find end of number *)
            let rec find_end j =
              if j >= len then j
              else let c2 = s.[j] in
                if (c2 >= '0' && c2 <= '9') || c2 = '.' then find_end (j + 1)
                else j
            in
            let end_pos = find_end i in
            let num_str = String.sub s i (end_pos - i) in
            (match float_of_string_opt num_str with
             | Some f when f >= 0.0 && f <= 1.0 -> Some f
             | _ -> scan end_pos)
          else scan (i + 1)
      in
      scan 0

(** Validate that an LLM response contains a parseable score. *)
let llm_score_is_valid (resp : Llm_types.completion_response) : bool =
  parse_llm_score (Llm_types.text_of_response resp) <> None

(** Call LLM to score agent-task compatibility.
    Returns Ok float or Error string. *)
let score_with_llm (agent : agent_profile) (task : task_profile)
    : (float, string) result =
  let prompt = build_scoring_prompt agent task in
  match
    Lodge_cascade.call ~cascade_name:"capability_match" ~prompt
      ~temperature:0.1 ~timeout_sec:15 ~max_tokens:20
      ~accept:llm_score_is_valid ()
  with
  | Ok r -> (
      match parse_llm_score r.response with
      | Some f -> Ok f
      | None -> Error (Printf.sprintf "unparseable LLM response: %s" r.response))
  | Error err -> Error err

(* ---------- Keyword Scoring ---------- *)

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

(** Compute keyword-based match score between an agent and a task.
    When the task has a required_role, agents without a matching role
    receive a total_score of 0.0 (filtered out). *)
let score_keyword (agent : agent_profile) (task : task_profile) : match_score =
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
  make_match_score ~mode:Keyword ~provenance:Derived
    ~agent_name:agent.name ~task_id:task.task_id
    ~trait_score ~interest_score ~capability_score ~total_score

(** Compute LLM-based match score. Falls back to keyword on parse failure. *)
let score_llm (agent : agent_profile) (task : task_profile) : match_score =
  let role_ok = Agent_identity.role_satisfies
    ~required:task.required_role ~agent_role:agent.role in
  if not role_ok then
    make_match_score ~mode:Llm ~provenance:Judgment
      ~agent_name:agent.name ~task_id:task.task_id
      ~trait_score:0.0 ~interest_score:0.0
      ~capability_score:0.0 ~total_score:0.0
  else
    match score_with_llm agent task with
    | Ok llm_score ->
        make_match_score ~mode:Llm ~provenance:Judgment
          ~agent_name:agent.name ~task_id:task.task_id
          ~trait_score:llm_score ~interest_score:llm_score
          ~capability_score:llm_score ~total_score:llm_score
    | Error _err ->
        (* LLM failed — return zero rather than silently falling back *)
        make_match_score ~mode:Llm ~provenance:Judgment
          ~agent_name:agent.name ~task_id:task.task_id
          ~trait_score:0.0 ~interest_score:0.0
          ~capability_score:0.0 ~total_score:0.0

(** Compute hybrid match score: LLM first, keyword fallback on failure. *)
let score_hybrid (agent : agent_profile) (task : task_profile) : match_score =
  let role_ok = Agent_identity.role_satisfies
    ~required:task.required_role ~agent_role:agent.role in
  if not role_ok then
    make_match_score ~mode:Hybrid ~provenance:Fallback
      ~agent_name:agent.name ~task_id:task.task_id
      ~trait_score:0.0 ~interest_score:0.0
      ~capability_score:0.0 ~total_score:0.0
  else
    match score_with_llm agent task with
    | Ok llm_score ->
        make_match_score ~mode:Hybrid ~provenance:Judgment
          ~agent_name:agent.name ~task_id:task.task_id
          ~trait_score:llm_score ~interest_score:llm_score
          ~capability_score:llm_score ~total_score:llm_score
    | Error _err ->
        (* LLM unavailable — fall back to keyword heuristic *)
        let keyword = score_keyword agent task in
        { keyword with mode = match_mode_to_string Hybrid; provenance = "fallback" }

(** Compute match score using the active mode (env var dispatch). *)
let score (agent : agent_profile) (task : task_profile) : match_score =
  match get_match_mode () with
  | Keyword -> score_keyword agent task
  | Llm -> score_llm agent task
  | Hybrid -> score_hybrid agent task

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
    ("mode", `String m.mode);
    ("provenance", `String m.provenance);
  ]

let ranking_to_json (scores : match_score list) : Yojson.Safe.t =
  `List (List.map match_score_to_json scores)
