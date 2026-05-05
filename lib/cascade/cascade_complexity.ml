(** See {!Cascade_complexity} interface. *)

type t = Simple | Moderate | Complex

let to_string = function
  | Simple -> "simple"
  | Moderate -> "moderate"
  | Complex -> "complex"

let of_string raw =
  match String.trim raw |> String.lowercase_ascii with
  | "simple" -> Some Simple
  | "moderate" -> Some Moderate
  | "complex" -> Some Complex
  | _ -> None

(** Env-driven thresholds with safe fallback. *)

let threshold_int env_key default =
  match Sys.getenv_opt env_key with
  | None | Some "" -> default
  | Some s ->
    (match int_of_string_opt (String.trim s) with
     | Some n -> n
     | None ->
       Log.Misc.warn "Invalid int for %s=%S, using default %d" env_key s default;
       default)

let simple_goal_chars_max =
  threshold_int "MASC_COMPLEXITY_SIMPLE_GOAL_CHARS" 2000

let simple_max_tokens_max =
  threshold_int "MASC_COMPLEXITY_SIMPLE_MAX_TOKENS" 1000

let moderate_goal_chars_max =
  threshold_int "MASC_COMPLEXITY_MODERATE_GOAL_CHARS" 8000

let moderate_max_tokens_max =
  threshold_int "MASC_COMPLEXITY_MODERATE_MAX_TOKENS" 4000

let detect ?(goal = "") ?(tools = []) ?(max_tokens = 0) () =
  let goal_chars = String.length goal in
  let has_tools = tools <> [] in
  (* Tools or high token counts always escalate to Complex — the
     provider must support tool_choice / structured output. *)
  if has_tools || max_tokens > moderate_max_tokens_max || goal_chars > moderate_goal_chars_max
  then Complex
  else if max_tokens > simple_max_tokens_max || goal_chars > simple_goal_chars_max
  then Moderate
  else Simple

let cascade_profile_of_complexity = function
  | Simple -> "tier_small"
  | Moderate -> "tier_medium"
  | Complex -> "big_three"

(** Kill switch: when [MASC_COMPLEXITY_ROUTING_ENABLED] is not ["true"],
    [maybe_reroute] returns the original cascade name unchanged.  This
    lets operators deploy the complexity classifier in observe-only mode
    alongside the existing cascade routing. *)
let routing_enabled =
  match Sys.getenv_opt "MASC_COMPLEXITY_ROUTING_ENABLED" with
  | Some s -> String.equal (String.trim s |> String.lowercase_ascii) "true"
  | None -> false

let maybe_reroute ~original_cascade_name complexity =
  if not routing_enabled then original_cascade_name
  else cascade_profile_of_complexity complexity
