(* Crew_council — Cycle 26 / Tier A9.
   See crew_council.mli for design rationale. *)

(* ── Phase phantom witnesses ──────────────────────────────────── *)

type propose = |
type critique = |
type research = |
type debate = |
type vote_phase = |
type decide = |

(* ── Phase GADT ───────────────────────────────────────────────── *)

type _ phase =
  | Propose : propose phase
  | Critique : critique phase
  | Research : research phase
  | Debate : debate phase
  | Vote : vote_phase phase
  | Decide : decide phase

type any_phase = Any_phase : 'a phase -> any_phase

(* ── Tag mirror ───────────────────────────────────────────────── *)

type phase_tag =
  | Tag_propose [@tla.symbol "propose"]
  | Tag_critique [@tla.symbol "critique"]
  | Tag_research [@tla.symbol "research"]
  | Tag_debate [@tla.symbol "debate"]
  | Tag_vote [@tla.symbol "vote"]
  | Tag_decide [@tla.symbol "decide"]
[@@deriving tla]

let all_phase_tags =
  [ Tag_propose; Tag_critique; Tag_research; Tag_debate; Tag_vote; Tag_decide ]

let phase_tag_to_string = to_tla_symbol

let phase_to_tag : type a. a phase -> phase_tag = function
  | Propose -> Tag_propose
  | Critique -> Tag_critique
  | Research -> Tag_research
  | Debate -> Tag_debate
  | Vote -> Tag_vote
  | Decide -> Tag_decide

let any_phase_to_tag (Any_phase p) = phase_to_tag p

let phase_to_string : type a. a phase -> string =
 fun p -> phase_tag_to_string (phase_to_tag p)

let any_phase_to_string (Any_phase p) = phase_to_string p

(* ── Transition GADT ──────────────────────────────────────────── *)

type ('from_phase, 'to_phase) transition =
  | Propose_to_critique : (propose, critique) transition
  | Critique_to_research : (critique, research) transition
  | Research_to_debate : (research, debate) transition
  | Debate_to_vote : (debate, vote_phase) transition
  | Vote_to_decide : (vote_phase, decide) transition

type any_transition =
  | Any_transition : ('from_phase, 'to_phase) transition -> any_transition

let all_transitions =
  [
    Any_transition Propose_to_critique;
    Any_transition Critique_to_research;
    Any_transition Research_to_debate;
    Any_transition Debate_to_vote;
    Any_transition Vote_to_decide;
  ]

let transition_from : type a b. (a, b) transition -> a phase = function
  | Propose_to_critique -> Propose
  | Critique_to_research -> Critique
  | Research_to_debate -> Research
  | Debate_to_vote -> Debate
  | Vote_to_decide -> Vote

let transition_to : type a b. (a, b) transition -> b phase = function
  | Propose_to_critique -> Critique
  | Critique_to_research -> Research
  | Research_to_debate -> Debate
  | Debate_to_vote -> Vote
  | Vote_to_decide -> Decide

let transition_to_string : type a b. (a, b) transition -> string =
 fun t ->
  Printf.sprintf "%s->%s"
    (phase_to_string (transition_from t))
    (phase_to_string (transition_to t))

let any_transition_to_string (Any_transition t) = transition_to_string t

(* ── Timeout policy ───────────────────────────────────────────── *)

type timeout_policy = {
  time_cap_per_phase_ms : int;
  global_deadline_ms : int;
}

let default_timeout =
  { time_cap_per_phase_ms = 30_000; global_deadline_ms = 180_000 }

(* ── Council snapshot ─────────────────────────────────────────── *)

type 'phase t = {
  council_id : Crew_types.council_id;
  members : Persona_contract.any_persona list;
  phase_witness : 'phase phase;
  started_at : float;
  timeout : timeout_policy;
}

let create ~council_id ~members ~timeout ~now =
  {
    council_id;
    members;
    phase_witness = Propose;
    started_at = now;
    timeout;
  }

let council_id c = c.council_id
let members c = c.members
let current_phase c = c.phase_witness
let any_phase_of c = Any_phase c.phase_witness
let started_at c = c.started_at
let timeout c = c.timeout

let advance : type a b. (a, b) transition -> a t -> b t =
 fun trans c ->
  {
    council_id = c.council_id;
    members = c.members;
    phase_witness = transition_to trans;
    started_at = c.started_at;
    timeout = c.timeout;
  }

(* ── JSON ─────────────────────────────────────────────────────── *)

let timeout_to_json t =
  `Assoc
    [
      ("time_cap_per_phase_ms", `Int t.time_cap_per_phase_ms);
      ("global_deadline_ms", `Int t.global_deadline_ms);
    ]

let to_json : type a. a t -> Yojson.Safe.t =
 fun c ->
  `Assoc
    [
      ("council_id", Crew_types.council_id_to_json c.council_id);
      ("phase", `String (phase_to_string c.phase_witness));
      ( "members",
        `List (List.map Persona_contract.any_to_json c.members) );
      ("started_at", `Float c.started_at);
      ("timeout", timeout_to_json c.timeout);
    ]

type any_council = Any_council : 'phase t -> any_council

let any_council_to_json (Any_council c) = to_json c
let any_council_id (Any_council c) = c.council_id
