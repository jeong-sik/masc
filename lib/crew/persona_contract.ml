(* Persona_contract — Cycle 25 / Tier A8.
   See persona_contract.mli for design rationale. *)

(* ── Phantom witnesses ────────────────────────────────────────── *)

type analyst = |
type executor = |
type scholar = |
type verifier = |

(* ── Contract record ──────────────────────────────────────────── *)

(* The phantom 'a parameter is unused at the value level — it
   lives purely in the type. Each constructor below narrows it
   to a specific witness so handler functions specialised on
   one persona cannot be misapplied. *)
type 'a contract = {
  name : string;
  description : string;
  core_responsibilities : string list;
  forbidden_tools : string list;
  kind : Crew_types.persona_kind;
}

(* ── Static contract values ───────────────────────────────────── *)

let analyst_contract : analyst contract =
  {
    name = "analyst";
    description =
      "Critical analyser. Surfaces hidden assumptions, decomposes \
       problems into checkable claims, flags rationalization \
       patterns in prior reasoning.";
    core_responsibilities =
      [
        "decompose claim into atomic checkable statements";
        "surface unstated assumption";
        "flag motivated reasoning";
        "name the trade-off explicitly";
      ];
    forbidden_tools = [ "external_api_call"; "shell_write" ];
    kind = Crew_types.Analyst;
  }

let executor_contract : executor contract =
  {
    name = "executor";
    description =
      "Action-taker. Carries out concrete edits, shell commands, \
       and tool calls per a plan handed down by analyst or \
       scholar. Owns the side-effecting tool surface.";
    core_responsibilities =
      [
        "execute approved plan steps";
        "report exit status + diff per step";
        "stop and ask when plan diverges from observed reality";
      ];
    forbidden_tools = [];
    kind = Crew_types.Executor;
  }

let scholar_contract : scholar contract =
  {
    name = "scholar";
    description =
      "Researcher. Pulls prior art, fetches documentation, \
       synthesises option lists. Read-only on the world; never \
       writes side effects.";
    core_responsibilities =
      [
        "retrieve canonical documentation";
        "summarise option space with trade-offs";
        "cite source for any factual claim";
      ];
    forbidden_tools = [ "shell_write"; "file_write"; "git_push" ];
    kind = Crew_types.Scholar;
  }

let verifier_contract : verifier contract =
  {
    name = "verifier";
    description =
      "Reviewer. Inspects artifacts produced by other personas, \
       runs evals, asserts correctness. Read + test-run; no \
       write side effects.";
    core_responsibilities =
      [
        "run declared eval gate";
        "diff against expected output";
        "produce verdict with evidence";
      ];
    forbidden_tools = [ "shell_write"; "file_write"; "git_push" ];
    kind = Crew_types.Verifier;
  }

(* ── Existential capture ──────────────────────────────────────── *)

type any_persona = Any_persona : 'a contract -> any_persona

let all_personas =
  [
    Any_persona analyst_contract;
    Any_persona executor_contract;
    Any_persona scholar_contract;
    Any_persona verifier_contract;
  ]

(* ── Accessors ────────────────────────────────────────────────── *)

let name c = c.name
let description c = c.description
let core_responsibilities c = c.core_responsibilities
let forbidden_tools c = c.forbidden_tools
let persona_kind c = c.kind

let any_persona_kind (Any_persona c) = c.kind
let any_name (Any_persona c) = c.name
let any_description (Any_persona c) = c.description

(* ── JSON ─────────────────────────────────────────────────────── *)

let to_json c =
  `Assoc
    [
      ("name", `String c.name);
      ("kind", Crew_types.persona_kind_to_json c.kind);
      ("description", `String c.description);
      ( "core_responsibilities",
        `List (List.map (fun s -> `String s) c.core_responsibilities) );
      ( "forbidden_tools",
        `List (List.map (fun s -> `String s) c.forbidden_tools) );
    ]

let any_to_json (Any_persona c) = to_json c
