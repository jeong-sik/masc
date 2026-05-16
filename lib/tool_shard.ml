module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_shard — Dynamic tool sharding for MASC agents.

    Allows tools to be granted/revoked at runtime like equipment slots.
    Each agent can have multiple active shards that contribute tools.

    @since 2.62.0 *)

(** Issue #8480: hand-mirrored from
    [Keeper_tool_pr_review.valid_pr_review_event_strings]. Direct
    dependency would create a cycle (Tool_shard -> Keeper_tool_pr_review
    -> Keeper_alerting -> Tool_shard). The sync regression test
    [test_types.ml :: pr_review_event_ssot] asserts these stay in
    lock-step so adding a new event in keeper_tool_pr_review.ml fails
    the test before shipping with a stale schema. *)

(* enum-string SSOT mirrors + type shard + StringMap moved to Tool_shard_types. *)
include Tool_shard_types
(** Predefined shards *)


(* base_tools schema list moved to Tool_shard_types. *)

(* board_tools schema list moved to Tool_shard_types. *)
(* select_named_schemas moved to Tool_shard_types
   (intra-library file split, 2026-05-16). *)


(* filesystem_tools schema list moved to Tool_shard_types. *)

(* shell_tools schema list moved to Tool_shard_types. *)

(* keeper_preflight_tools + keeper_github_pr_tools schemas moved to Tool_shard_types. *)

(* keeper_pr_review_tools + coding_workspace_tool_names moved to Tool_shard_types. *)
let coding_workspace_tools : Masc_domain.tool_schema list =
  select_named_schemas
    coding_workspace_tool_names
    (Tool_schemas_worktree.schemas @ Tool_code.schemas)
;;

(** Coding tools — shell/github bridges plus worktree-first code workflow.
    Always granted. *)
let coding_tools : Masc_domain.tool_schema list =
  coding_keeper_bridge_tools
  @ coding_workspace_tools
  @ keeper_preflight_tools
  @ keeper_github_pr_tools
  @ keeper_pr_review_tools
;;

(* voice_tools, library_tools, taskboard_tools moved to Tool_shard_types. *)

(** Predefined shards *)

let shard_base : shard =
  { name = "base"
  ; tools = base_tools
  ; read_only_tools =
      [ "keeper_stay_silent"
      ; "keeper_time_now"
      ; "keeper_context_status"
      ; "keeper_memory_search"
      ; "keeper_tools_list"
      ]
  ; removable = false
  ; description = "Core tools: time, context, memory"
  }
;;

let shard_board : shard =
  { name = "board"
  ; tools = board_tools
  ; read_only_tools =
      [ "keeper_board_get"
      ; "keeper_board_list"
      ; "keeper_board_stats"
      ; "keeper_board_search"
      ; "keeper_board_curation_read"
      ; "keeper_board_sub_board_list"
      ; "keeper_board_sub_board_get"
      ]
  ; removable = true
  ; description = "MASC Board: post, list, comment"
  }
;;

let shard_filesystem : shard =
  { name = "filesystem"
  ; tools = filesystem_tools
  ; read_only_tools = [ "keeper_fs_read" ]
  ; removable = true
  ; description = "File I/O: read and write"
  }
;;

let shard_shell : shard =
  { name = "shell"
  ; tools = shell_tools
  ; read_only_tools = [ "keeper_shell" ]
  ; removable = true
  ; description = "Shell ops: pwd, ls, cat, rg, git_status, git_clone"
  }
;;

let shard_coding : shard =
  { name = "coding"
  ; tools = coding_tools
  ; read_only_tools = []
  ; removable = true
  ; description = "Coding tools: github/shell bridge + worktree/code inspection"
  }
;;

let shard_voice : shard =
  { name = "voice"
  ; tools = voice_tools
  ; read_only_tools = [ "keeper_voice_sessions" ]
  ; removable = true
  ; description = "Voice bridge speak output"
  }
;;

let shard_library : shard =
  { name = "library"
  ; tools = library_tools
  ; read_only_tools = [ "keeper_library_search"; "keeper_library_read" ]
  ; removable = true
  ; description = "Knowledge library: search, read documents"
  }
;;

let shard_taskboard : shard =
  { name = "taskboard"
  ; tools = taskboard_tools
  ; read_only_tools = [ "keeper_tasks_list"; "keeper_tasks_audit" ]
  ; removable = true
  ; description =
      "Task board management: list, audit, force-release, force-done, broadcast"
  }
;;

(** Autoresearch tools available to keepers. *)
let autoresearch_keeper_tools : Masc_domain.tool_schema list =
  Tool_autoresearch_schemas.schemas
;;

let shard_autoresearch : shard =
  { name = "autoresearch"
  ; tools = autoresearch_keeper_tools
  ; read_only_tools = []
  ; removable = true
  ; description =
      "Autonomous experiment loop: start, cycle, status, inject, stop, findings"
  }
;;

(** Per-agent shard overrides.  Read-modify-write is serialised by
    [agent_shards_mutex] so concurrent keeper setup calls cannot lose updates.

    Stdlib.Mutex (not Eio.Mutex) because these helpers are also called from
    non-Eio contexts — unit tests and some startup wiring — where Eio.Mutex
    raises Effect.Unhandled(Cancel.Get_context). Critical sections are short
    StringMap ops, so Stdlib blocking is acceptable.
    See memory/feedback_ocaml5-mutex-selection.md. *)
let agent_shards : string list StringMap.t ref = ref StringMap.empty

let agent_shards_mutex = Stdlib.Mutex.create ()

(** Default shards for a new keeper.
    Autoresearch is intentionally opt-in through the explicit shard or
    a preset/tool policy group. *)
(* default_shard_names moved to Tool_shard_types
   (intra-library file split, 2026-05-16). *)

let get_agent_shards (agent_name : string) : string list =
  Stdlib.Mutex.protect agent_shards_mutex (fun () ->
    StringMap.find_opt agent_name !agent_shards
    |> Option.value ~default:default_shard_names)
;;

let set_agent_shards (agent_name : string) (shards : string list) : unit =
  Stdlib.Mutex.protect agent_shards_mutex (fun () ->
    agent_shards
    := StringMap.add agent_name (List.sort_uniq String.compare shards) !agent_shards)
;;

let remove_agent_shards (agent_name : string) : unit =
  Stdlib.Mutex.protect agent_shards_mutex (fun () ->
    agent_shards := StringMap.remove agent_name !agent_shards)
;;

(** All predefined shards by name *)
let all_shards : shard StringMap.t =
  List.fold_left
    (fun map s -> StringMap.add s.name s map)
    StringMap.empty
    [ shard_base
    ; shard_board
    ; shard_filesystem
    ; shard_shell
    ; shard_coding
    ; shard_voice
    ; shard_library
    ; shard_taskboard
    ; shard_autoresearch
    ]
;;

let all_read_only_keeper_tools () : string list =
  StringMap.fold (fun _name shard acc -> shard.read_only_tools @ acc) all_shards []
  |> List.sort_uniq String.compare
;;

(* #10101: single SSOT for every keeper-facing tool schema exposed
   by this module.  Feeds [Config.raw_all_tool_schemas] so
   [Tool_help_registry.find_entry] can resolve ANY shard tool,
   not just the five base tools that the earlier #9912 patch
   registered.

   Built from [all_shards] (every shard category flows through
   automatically — no future fix will regress the registry when
   a new shard is added) plus the two non-shard tool lists
   [keeper_preflight_tools], [keeper_github_pr_tools], and [keeper_pr_review_tools] that
   live in this module but are not owned by any shard definition.

   Callers must still run [Config.dedupe_schemas] because a
   single tool can appear under multiple shards (e.g. tools that
   [shard_coding] composes from [shard_shell]) and the schema
   list may overlap with other roots (Tools.raw_schemas). *)
let all_keeper_tool_schemas : Masc_domain.tool_schema list =
  let shard_schemas =
    StringMap.fold (fun _name (shard : shard) acc -> shard.tools @ acc) all_shards []
  in
  shard_schemas @ keeper_preflight_tools @ keeper_github_pr_tools @ keeper_pr_review_tools
;;

let recovery_minimum_shard_names () : string list =
  StringMap.fold
    (fun name shard acc -> if not shard.removable then name :: acc else acc)
    all_shards
    []
  |> List.rev
;;

(** Get a shard by name *)
let get_shard (name : string) : shard option = StringMap.find_opt name all_shards

(** Combine tools from multiple shard names *)
let tools_of_shards (shard_names : string list) : Masc_domain.tool_schema list =
  shard_names
  |> List.filter_map (fun name -> StringMap.find_opt name all_shards)
  |> List.concat_map (fun (s : shard) -> s.tools)
;;

(** {1 Dynamic Shard Management} *)

(** Grant a shard to an agent. Returns new active_shards list.
    Fails if shard doesn't exist or is already granted. *)
let grant_shard (active_shards : string list) (shard_name : string)
  : (string list, string) Result.t
  =
  match StringMap.find_opt shard_name all_shards with
  | None -> Error (Printf.sprintf "Unknown shard: %s" shard_name)
  | Some _ ->
    if List.mem shard_name active_shards
    then Error (Printf.sprintf "Shard already granted: %s" shard_name)
    else Ok (active_shards @ [ shard_name ])
;;

(** Revoke a shard from an agent. Returns new active_shards list.
    Fails if shard is not removable or not currently granted. *)
let revoke_shard (active_shards : string list) (shard_name : string)
  : (string list, string) Result.t
  =
  match StringMap.find_opt shard_name all_shards with
  | None -> Error (Printf.sprintf "Unknown shard: %s" shard_name)
  | Some shard ->
    if not shard.removable
    then Error (Printf.sprintf "Cannot revoke non-removable shard: %s" shard_name)
    else if not (List.mem shard_name active_shards)
    then Error (Printf.sprintf "Shard not currently granted: %s" shard_name)
    else Ok (List.filter (fun n -> not (String.equal n shard_name)) active_shards)
;;

(** List all available shards with their status *)
let list_all_shards () : (string * bool * int) list =
  StringMap.fold
    (fun name (shard : shard) acc ->
       (name, shard.removable, List.length shard.tools) :: acc)
    all_shards
    []
  |> List.rev
;;

(** Default keeper tool set from [default_shard_names]. *)
let keeper_model_tools : Masc_domain.tool_schema list =
  tools_of_shards default_shard_names
;;


(** Re-exported from {!Tool_shard_schemas}. *)
let schemas = Tool_shard_schemas.schemas

(** {1 MCP Execute} *)

let active_shards_of_agent agent_name_opt =
  match agent_name_opt with
  | Some name -> get_agent_shards name
  | None -> default_shard_names
;;

(** Execute tool_shard MCP tools. *)
let execute (tool_name : string) (arguments : Yojson.Safe.t) : bool * Yojson.Safe.t =
  let module U = Yojson.Safe.Util in
  let read_required_string key =
    match U.member key arguments with
    | `String v when not (String.equal (String.trim v) "") -> Some v
    | _ -> None
  in
  match tool_name with
  | "masc_tool_list" ->
    let agent_name = read_required_string "agent_name" in
    let all = list_all_shards () in
    let active_shards = active_shards_of_agent agent_name in
    let shard_list =
      List.map
        (fun (name, removable, tool_count) ->
           `Assoc
             [ "name", `String name
             ; "removable", `Bool removable
             ; "tool_count", `Int tool_count
             ])
        all
    in
    let active_shards =
      List.filter_map
        (fun (name, _, _) ->
           Option.map
             (fun () -> `String name)
             (if List.mem name active_shards then Some () else None))
        all
    in
    ( true
    , `Assoc
        [ "shards", `List shard_list
        ; "agent_name", `String (Option.value ~default:"" agent_name)
        ; "active_shards", `List active_shards
        ] )
  | "masc_tool_grant" | "masc_tool_revoke" ->
    let op_fn, status_label =
      if String.equal tool_name "masc_tool_grant"
      then grant_shard, "granted"
      else revoke_shard, "revoked"
    in
    let agent_name = read_required_string "agent_name" in
    let shard_name = read_required_string "shard_name" in
    (match agent_name, shard_name with
     | Some agent_name, Some shard_name ->
       (match op_fn (get_agent_shards agent_name) shard_name with
        | Ok next_shards ->
          set_agent_shards agent_name next_shards;
          ( true
          , `Assoc
              [ "status", `String status_label
              ; "agent_name", `String agent_name
              ; "shard", `String shard_name
              ; "active_shards", `List (List.map (fun s -> `String s) next_shards)
              ] )
        | Error msg ->
          false, Tool_args.error_assoc [ "message", `String msg ])
     | _ ->
       ( false
       , Tool_args.error_assoc
           [ "message", `String "agent_name and shard_name are required" ] ))
  | _ -> false, `String "Unknown tool"
;;

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

(* tool_spec_read_only / tool_spec_destructive / tool_required_permission /
   tool_effect_domain moved to Tool_shard_types (intra-library file split,
   2026-05-16). *)

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
       Tool_spec.register
         (Tool_spec.create
            ~name:s.name
            ~description:s.description
            ~module_tag:Tool_dispatch.Mod_shard
            ~input_schema:s.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:(List.mem s.name tool_spec_read_only)
            ~is_idempotent:(List.mem s.name tool_spec_read_only)
            ~is_destructive:(List.mem s.name tool_spec_destructive)
            ?required_permission:(tool_required_permission s.name)
            ?effect_domain:(tool_effect_domain s.name)
            ()))
    schemas
;;
