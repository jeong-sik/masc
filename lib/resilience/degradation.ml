(* Degradation — Cycle 27 / Tier A11 (degradation half).
   See degradation.mli for design rationale. *)

(* ── Phantom witnesses ────────────────────────────────────────── *)

type full_capability = |
type reduced_capability = |
type skeleton_capability = |
type fallback_capability = |

(* ── Level GADT ───────────────────────────────────────────────── *)

type _ level =
  | L1 : full_capability level
  | L2 : reduced_capability level
  | L3 : skeleton_capability level
  | L4 : fallback_capability level

type any_level = Any_level : 'a level -> any_level

(* ── Tag mirror ───────────────────────────────────────────────── *)

type level_tag = Tag_l1 | Tag_l2 | Tag_l3 | Tag_l4

let all_level_tags = [ Tag_l1; Tag_l2; Tag_l3; Tag_l4 ]

let level_tag_to_string = function
  | Tag_l1 -> "L1"
  | Tag_l2 -> "L2"
  | Tag_l3 -> "L3"
  | Tag_l4 -> "L4"

let level_to_tag : type a. a level -> level_tag = function
  | L1 -> Tag_l1
  | L2 -> Tag_l2
  | L3 -> Tag_l3
  | L4 -> Tag_l4

let any_level_to_tag (Any_level l) = level_to_tag l

let level_to_string : type a. a level -> string =
 fun l -> level_tag_to_string (level_to_tag l)

(* ── Numeric mapping ──────────────────────────────────────────── *)

let to_int : type a. a level -> int = function
  | L1 -> 1
  | L2 -> 2
  | L3 -> 3
  | L4 -> 4

let any_to_int (Any_level l) = to_int l

let of_int_opt = function
  | 1 -> Some (Any_level L1)
  | 2 -> Some (Any_level L2)
  | 3 -> Some (Any_level L3)
  | 4 -> Some (Any_level L4)
  | _ -> None

(* ── Authorization (stub) ─────────────────────────────────────── *)

let authorize_transition ~from:_ ~to_:_ = Ok ()

(* ── Strategy adjustment ──────────────────────────────────────── *)

let error_mode_kind_label (mode : Recovery.error_mode) : string =
  match mode with
  | Recovery.TransientError _ -> "Transient"
  | Recovery.PermanentError _ -> "Permanent"
  | Recovery.ResourceExhausted _ -> "ResourceExhausted"
  | Recovery.AmbiguityError _ -> "Ambiguity"
  | Recovery.ConsensusError _ -> "Consensus"
  | Recovery.DegradationRequired _ -> "DegradationRequired"

let apply_level_to_strategy : type a.
    a level ->
    Recovery.error_mode ->
    [ `Retry | `Fallback | `Handoff | `Abort ] Recovery.strategy =
 fun lvl mode ->
  match lvl with
  | L1 -> Recovery.default_strategy mode
  | L2 -> (
      (* Reduced capability: a Retry that would otherwise drive
         the same failing path becomes a Fallback substitution. *)
      match Recovery.default_strategy mode with
      | Recovery.Retry _ ->
          Recovery.Fallback
            { fallback_value = "<degraded:L2>"; degrade_confidence_by = 0.3 }
      | other -> other)
  | L3 ->
      Recovery.Handoff
        {
          operator_message =
            Printf.sprintf
              "Degradation L3 (skeleton): tool use disabled. Original \
               error mode: %s"
              (error_mode_kind_label mode);
          preserve_state = true;
        }
  | L4 ->
      Recovery.Abort
        {
          reason =
            Printf.sprintf
              "Degradation L4 (fallback): canned response only. \
               Original error mode: %s"
              (error_mode_kind_label mode);
          cleanup = (fun () -> ());
        }
