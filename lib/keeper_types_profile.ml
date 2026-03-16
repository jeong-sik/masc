(** Keeper_types_profile — keeper profile defaults, persona loading,
    and directory path helpers.

    Extracted from keeper_types.ml to reduce file size.
    Depends only on Keeper_config (no Keeper_types dependency). *)

include Keeper_config
let keeper_debug =
  match Sys.getenv_opt "MASC_KEEPER_DEBUG" with
  | Some "1" -> true
  | _ -> false

type 'a context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type tool_result = bool * string

let schemas = Keeper_schema.schemas

(* Configuration: see Keeper_config *)
include Keeper_config

let short_preview ?(max_len = 220) (s : string) : string =
  let s = String.trim s in
  if String.length s <= max_len then s
  else utf8_safe_prefix_bytes s ~max_bytes:max_len ^ "..."

let normalize_similarity_text (s : string) : string =
  let len = String.length s in
  let buf = Bytes.create len in
  for i = 0 to len - 1 do
    let c = Char.lowercase_ascii s.[i] in
    let keep =
      (c >= 'a' && c <= 'z')
      || (c >= '0' && c <= '9')
      || c = ' '
    in
    Bytes.set buf i (if keep then c else ' ')
  done;
  Bytes.to_string buf

let similarity_tokens (s : string) : string list =
  s
  |> normalize_similarity_text
  |> Str.split (Str.regexp "[ \t\r\n]+")
  |> List.filter (fun t -> String.length t >= 2)

let jaccard_similarity (a : string list) (b : string list) : float =
  let to_set xs =
    List.fold_left
      (fun acc x -> if List.mem x acc then acc else x :: acc)
      []
      xs
  in
  let sa = to_set a in
  let sb = to_set b in
  if sa = [] && sb = [] then 1.0
  else
    let inter =
      List.fold_left (fun n x -> if List.mem x sb then n + 1 else n) 0 sa
    in
    let union = List.length sa + List.length sb - inter in
    if union <= 0 then 0.0 else float_of_int inter /. float_of_int union

let proactive_similarity_score ~(candidate : string) ~(previous : string) : float =
  let a = similarity_tokens candidate in
  let b = similarity_tokens previous in
  jaccard_similarity a b

let soul_profile_policy profile =
  match profile with
  | "safety" ->
      "SOUL profile: safety-first.\n\
       Preserve first: user safety boundaries, explicit consent constraints, unresolved risks, and trust continuity.\n\
       Keep policy/guardrail decisions before optimization details."
  | "delivery" ->
      "SOUL profile: delivery.\n\
       Preserve first: concrete goal progress, accepted decisions, blockers, and next executable steps.\n\
       Keep implementation tradeoffs and done/not-done boundaries."
  | "research" ->
      "SOUL profile: research.\n\
       Preserve first: hypotheses, evidence, source-backed findings, and confidence/uncertainty.\n\
       Keep why conclusions changed, not just final statements."
  | "relationship" ->
      "SOUL profile: relationship.\n\
       Preserve first: user preferences, tone cues, collaboration style, and long-lived context about expectations.\n\
       Keep agreements and communication constraints."
  | "minimal" ->
      "SOUL profile: minimal.\n\
       Preserve only high-signal continuity: current goal, single most important decision, top blocker, and next action.\n\
       Aggressively drop low-value historical detail."
  | _ ->
      "SOUL profile: balanced.\n\
       Preserve in this order: safety/trust continuity, goal progress & decisions, unresolved risks, tool outcomes, style preferences."

let proactive_seed_for_soul_profile (profile : string) : string =
  match canonical_soul_profile profile |> Option.value ~default:default_soul_profile with
  | "safety" ->
      "Safety hint: prioritize current risk signals and mitigations."
  | "delivery" ->
      "Delivery hint: prioritize concrete next actions and execution momentum."
  | "research" ->
      "Research hint: prioritize hypotheses, evidence, and validation steps."
  | "relationship" ->
      "Relationship hint: prioritize user intent alignment and collaboration continuity."
  | "minimal" ->
      "Minimal hint: keep only high-signal continuity and next move."
  | _ ->
      "Balanced hint: keep a practical mix of risk, progress, and next step."

let take n xs =
  let rec go i acc = function
    | [] -> List.rev acc
    | _ when i <= 0 -> List.rev acc
    | x :: rest -> go (i - 1) (x :: acc) rest
  in
  go n [] xs

let mkdir_p path =
  let rec go p =
    if p = "" || p = "/" then ()
    else if Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      (try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  go path

let dedupe_keep_order items =
  let seen = Hashtbl.create (List.length items) in
  List.filter
    (fun item ->
      if Hashtbl.mem seen item then
        false
      else (
        Hashtbl.add seen item ();
        true))
    items

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b

let resolve_allowed_models ~explicit_allowed_models ~seed_allowed_models ~models =
  if explicit_allowed_models <> [] then
    dedupe_keep_order explicit_allowed_models
  else if seed_allowed_models <> [] then
    dedupe_keep_order seed_allowed_models
  else
    dedupe_keep_order models

let canonical_room_scope = function
  | "all" -> "all"
  | _ -> "current"

let canonical_scope_kind = function
  | "global" -> "global"
  | _ -> "local"

let canonical_trigger_mode = function
  | "explicit_only" -> "explicit_only"
  | _ -> "legacy"

let canonical_policy_mode = function
  | "learned_offline_v1" -> "learned_offline_v1"
  | "explicit_event_v1" -> "explicit_event_v1"
  | "llm_deliberation" -> "llm_deliberation"
  | _ -> "heuristic"

let canonical_voice_channel = function
  | "voice_only" -> "voice_only"
  | "text_only" -> "text_only"
  | _ -> "voice_text"

let default_voice_enabled_for name =
  String.equal (String.lowercase_ascii (String.trim name)) "sangsu"

let default_voice_channel_for name =
  if default_voice_enabled_for name then "voice_text" else "text_only"

let default_voice_agent_id_for name =
  if default_voice_enabled_for name then name else ""

let canonical_policy_action_budget = function
  | "board" -> "board"
  | _ -> "conversation"

let canonical_policy_shell_mode = function
  | "readonly" -> "readonly"
  | _ -> "disabled"

let canonical_initiative_scope = function
  | "board_only" -> "board_only"
  | _ -> "board_only"

let canonical_initiative_context_mode = function
  | "board_snapshot" -> "board_snapshot"
  | _ -> "board_snapshot"

let normalize_initiative_idle_sec (v : int) : int =
  clamp_int v ~min_v:3600 ~max_v:604800

let normalize_initiative_cooldown_sec (v : int) : int =
  clamp_int v ~min_v:3600 ~max_v:604800

let normalize_initiative_post_ttl_hours (v : int) : int =
  clamp_int v ~min_v:1 ~max_v:168

let room_seq_map_to_json (items : (string * int) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (room_id, seq) -> (room_id, `Int seq)) items)

let room_seq_map_of_json (json : Yojson.Safe.t) : (string * int) list =
  match json with
  | `Assoc fields ->
      fields
      |> List.filter_map (fun (room_id, value) ->
             if not (validate_name room_id) then
               None
             else
               match value with
               | `Int seq -> Some (room_id, seq)
               | `Intlit raw ->
                   Some (room_id, Safe_ops.int_of_string_with_default ~default:0 raw)
               | _ -> None)
  | _ -> []


type keeper_profile_defaults = {
  manifest_path : string option;
  goal : string option;
  short_goal : string option;
  mid_goal : string option;
  long_goal : string option;
  soul_profile : string option;
  will : string option;
  needs : string option;
  desires : string option;
  instructions : string option;
  models : string list;
  allowed_models : string list;
  active_model : string option;
  policy_mode : string option;
  policy_action_budget : string option;
  policy_reward_model_path : string option;
  policy_voice_enabled : bool option;
  policy_shell_mode : string option;
  initiative_enabled : bool option;
  initiative_scope : string option;
  initiative_idle_sec : int option;
  initiative_cooldown_sec : int option;
  initiative_context_mode : string option;
  initiative_post_ttl_hours : int option;
  room_scope : string option;
  scope_kind : string option;
  trigger_mode : string option;
  mention_targets : string list;
  presence_keepalive : bool option;
  presence_keepalive_sec : int option;
  proactive_enabled : bool option;
}

type persona_summary = {
  persona_name : string;
  display_name : string;
  role : string option;
  trait : string option;
  profile_path : string;
  has_keeper_defaults : bool;
}

let empty_keeper_profile_defaults = {
  manifest_path = None;
  goal = None;
  short_goal = None;
  mid_goal = None;
  long_goal = None;
  soul_profile = None;
  will = None;
  needs = None;
  desires = None;
  instructions = None;
  models = [];
  allowed_models = [];
  active_model = None;
  policy_mode = None;
  policy_action_budget = None;
  policy_reward_model_path = None;
  policy_voice_enabled = None;
  policy_shell_mode = None;
  initiative_enabled = None;
  initiative_scope = None;
  initiative_idle_sec = None;
  initiative_cooldown_sec = None;
  initiative_context_mode = None;
  initiative_post_ttl_hours = None;
  room_scope = None;
  scope_kind = None;
  trigger_mode = None;
  mention_targets = [];
  presence_keepalive = None;
  presence_keepalive_sec = None;
  proactive_enabled = None;
}

let personas_root_opt () =
  try
    let me_root = Env_config.me_root () in
    let path = Filename.concat me_root "personas" in
    if Sys.file_exists path && Sys.is_directory path then Some path else None
  with
  | Sys_error _ -> None
  | exn ->
      Log.Keeper.warn "personas_root_opt unexpected: %s" (Printexc.to_string exn);
      None

let persona_profile_path_opt name =
  match personas_root_opt () with
  | None -> None
  | Some root ->
      let path = Filename.concat (Filename.concat root name) "profile.json" in
      if Sys.file_exists path then Some path else None

let load_keeper_profile_defaults name : keeper_profile_defaults =
  match persona_profile_path_opt name with
  | None -> empty_keeper_profile_defaults
  | Some path -> (
      match Safe_ops.read_json_file_safe path with
      | Error _ -> empty_keeper_profile_defaults
      | Ok json ->
          let keeper_json = Yojson.Safe.Util.member "keeper" json in
          match keeper_json with
          | `Assoc _ ->
              {
                manifest_path = Some path;
                goal = Safe_ops.json_string_opt "goal" keeper_json;
                short_goal =
                  normalize_goal_horizon_opt (Safe_ops.json_string_opt "short_goal" keeper_json);
                mid_goal =
                  normalize_goal_horizon_opt (Safe_ops.json_string_opt "mid_goal" keeper_json);
                long_goal =
                  normalize_goal_horizon_opt (Safe_ops.json_string_opt "long_goal" keeper_json);
                soul_profile = Safe_ops.json_string_opt "soul_profile" keeper_json;
                will = Safe_ops.json_string_opt "will" keeper_json;
                needs = Safe_ops.json_string_opt "needs" keeper_json;
                desires = Safe_ops.json_string_opt "desires" keeper_json;
                instructions = Safe_ops.json_string_opt "instructions" keeper_json;
                models = Safe_ops.json_string_list "models" keeper_json;
                allowed_models = Safe_ops.json_string_list "allowed_models" keeper_json;
                active_model = Safe_ops.json_string_opt "active_model" keeper_json;
                policy_mode =
                  Safe_ops.json_string_opt "policy_mode" keeper_json
                  |> Option.map canonical_policy_mode;
                policy_action_budget =
                  Safe_ops.json_string_opt "policy_action_budget" keeper_json
                  |> Option.map canonical_policy_action_budget;
                policy_reward_model_path =
                  Safe_ops.json_string_opt "policy_reward_model_path" keeper_json;
                policy_voice_enabled =
                  (match Yojson.Safe.Util.member "policy_voice_enabled" keeper_json with
                  | `Bool flag -> Some flag
                  | _ -> None);
                policy_shell_mode =
                  Safe_ops.json_string_opt "policy_shell_mode" keeper_json
                  |> Option.map canonical_policy_shell_mode;
                initiative_enabled =
                  (match Yojson.Safe.Util.member "initiative_enabled" keeper_json with
                  | `Bool flag -> Some flag
                  | _ -> None);
                initiative_scope =
                  Safe_ops.json_string_opt "initiative_scope" keeper_json
                  |> Option.map canonical_initiative_scope;
                initiative_idle_sec =
                  Safe_ops.json_int_opt "initiative_idle_sec" keeper_json
                  |> Option.map normalize_initiative_idle_sec;
                initiative_cooldown_sec =
                  Safe_ops.json_int_opt "initiative_cooldown_sec" keeper_json
                  |> Option.map normalize_initiative_cooldown_sec;
                initiative_context_mode =
                  Safe_ops.json_string_opt "initiative_context_mode" keeper_json
                  |> Option.map canonical_initiative_context_mode;
                initiative_post_ttl_hours =
                  Safe_ops.json_int_opt "initiative_post_ttl_hours" keeper_json
                  |> Option.map normalize_initiative_post_ttl_hours;
                room_scope = Safe_ops.json_string_opt "room_scope" keeper_json;
                scope_kind = Safe_ops.json_string_opt "scope_kind" keeper_json;
                trigger_mode = Safe_ops.json_string_opt "trigger_mode" keeper_json;
                mention_targets = Safe_ops.json_string_list "mention_targets" keeper_json;
                presence_keepalive = Safe_ops.json_bool_opt "presence_keepalive" keeper_json;
                presence_keepalive_sec = Safe_ops.json_int_opt "presence_keepalive_sec" keeper_json;
                proactive_enabled = Safe_ops.json_bool_opt "proactive_enabled" keeper_json;
              }
          | _ -> { empty_keeper_profile_defaults with manifest_path = Some path })

let load_persona_summary name : persona_summary option =
  match persona_profile_path_opt name with
  | None -> None
  | Some path -> (
      match Safe_ops.read_json_file_safe path with
      | Error _ -> None
      | Ok json ->
          let display_name =
            Safe_ops.json_string_opt "name" json |> Option.value ~default:name
          in
          let role = Safe_ops.json_string_opt "role" json in
          let trait = Safe_ops.json_string_opt "trait" json in
          let has_keeper_defaults =
            match Yojson.Safe.Util.member "keeper" json with
            | `Assoc _ -> true
            | _ -> false
          in
          Some
            {
              persona_name = name;
              display_name;
              role;
              trait;
              profile_path = path;
              has_keeper_defaults;
            })

let list_persona_summaries () : persona_summary list =
  match personas_root_opt () with
  | None -> []
  | Some root ->
      root
      |> Sys.readdir
      |> Array.to_list
      |> List.filter validate_name
      |> List.filter_map load_persona_summary
      |> List.sort (fun a b -> String.compare a.persona_name b.persona_name)

let keeper_dir (config : Room.config) =
  let d = Filename.concat (Filename.concat config.base_path ".masc") "perpetual-keepers" in
  mkdir_p d;
  d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir (config : Room.config) =
  Filename.concat (Filename.concat config.base_path ".masc") "perpetual"

let keeper_agent_name name =
  Printf.sprintf "keeper-%s-agent" name

