type posture =
  | Native_none
  | Native_read
  | Native_full

type action_identity =
  | Call_id of string
  | Provider_step of
      { conversation_id : string
      ; step_index : int
      }

type origin =
  | Built_in
  | Mcp_wrapper

type observation =
  { identity : action_identity option
  ; tool_name : string option
  ; origin : origin
  }

type exact_action = action_identity * string

let valid_identity = function
  | Call_id call_id -> String.trim call_id <> ""
  | Provider_step { conversation_id; step_index } ->
    String.trim conversation_id <> "" && step_index >= 0
;;

let exact_action (observation : observation) =
  match observation with
  | { identity = Some identity; tool_name = Some tool_name; origin = Built_in }
    when valid_identity identity && String.trim tool_name <> "" ->
    Some (identity, tool_name)
  | { origin = Mcp_wrapper; _ }
  | { identity = None; _ }
  | { tool_name = None; _ }
  | { identity = Some _; tool_name = Some _ } -> None
;;

let observe_exact_action ~official_turn ~observe observation =
  Option.iter
    (fun (identity, tool_name) -> observe ~official_turn ~identity ~tool_name)
    (exact_action observation)
;;

let call_id observation =
  match observation.identity with
  | Some (Call_id call_id) -> Some call_id
  | Some (Provider_step _) | None -> None
;;

let stream_content_type = "native_tool_use"

let to_string = function
  | Native_none -> "none"
  | Native_read -> "read"
  | Native_full -> "full"
;;

let of_string = function
  | "none" -> Some Native_none
  | "read" -> Some Native_read
  | "full" -> Some Native_full
  | _ -> None
;;

let valid_posture_strings = [ "none"; "read"; "full" ]
let claude_code_default = Native_none
let codex_default = Native_read
let antigravity_default = Native_read

(* WebFetch/WebSearch observe no local state but do reach the network, so
   they stay out of the read set until the RFC widens it deliberately. *)
let claude_code_read_tool_names = [ "Read"; "Glob"; "Grep" ]

(* RFC-0390 admission review: a declared posture that admission cannot
   honor resolves to the posture the client actually runs, instead of
   failing the whole runtime call. [full] under a non-yolo approval mode
   becomes [read] (effects stay behind the gate) — a true downgrade,
   reported per turn because the approval mode is turn state. [none] on
   a client without a disable switch becomes [read] (the client's own
   floor: its built-ins keep running no matter what we pass) — this is
   NOT a downgrade but a static contradiction (profile says [none],
   runtime.toml assigned a runtime that cannot honor it), so the event
   is reported once per process, not per turn (#30408 review). *)
let degrade_on_admission ~posture ~none_supported () =
  match (posture, none_supported) with
  | Native_full, _ -> Native_read
  | Native_none, false -> Native_read
  | posture, _ -> posture
;;

let claude_code_tools_arg = function
  | Native_none -> ""
  | Native_read -> String.concat "," claude_code_read_tool_names
  | Native_full -> "default"
;;

(* Which Claude Code settings layers the CLI may load. The empty list — the
   default everywhere — keeps the historical [--setting-sources=] (no layer at
   all), so skills, hooks, subagents, and CLAUDE.md from disk stay off unless
   a keeper profile opts in. Closed variant rather than pass-through strings:
   a typo like "projcet" must fail the profile load, not silently select no
   layer. *)
type claude_setting_source =
  | Settings_user
  | Settings_project
  | Settings_local

let claude_setting_source_to_string = function
  | Settings_user -> "user"
  | Settings_project -> "project"
  | Settings_local -> "local"
;;

let claude_setting_sources_arg sources =
  "--setting-sources="
  ^ String.concat "," (List.map claude_setting_source_to_string sources)
;;
