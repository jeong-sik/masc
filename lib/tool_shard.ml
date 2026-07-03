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

(* enum-string SSOT mirrors + type shard + StringMap moved to Tool_shard_types. *)
include Tool_shard_types
(** Predefined shards *)


(* base_tools schema list moved to Tool_shard_types. *)

(* board_tools schema list moved to Tool_shard_types. *)
(* select_named_schemas moved to Tool_shard_types
   (intra-library file split, 2026-05-16). *)


(* filesystem_tools schema list moved to Tool_shard_types. *)

(* search_files_tools schema list moved to Tool_shard_types. *)

let unsharded_default_tools : Masc_domain.tool_schema list =
  typed_execute_tools
;;

(* voice_tools, library_tools, taskboard_tools moved to Tool_shard_types. *)

(** Predefined shards *)

let shard_base : shard =
  { name = "base"
  ; tools = base_tools
  ; read_only_tools =
      [ "keeper_time_now"
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
      [ "keeper_board_post_get"
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
  ; read_only_tools = [ "tool_read_file" ]
  ; removable = true
  ; description = "File I/O: read and write"
  }
;;

let shard_search_files : shard =
  { name = "search_files"
  ; tools = search_files_tools
  ; read_only_tools = [ "tool_search_files" ]
  ; removable = true
  ; description = "Grep: structured repo inspection"
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

(* RFC-0223 P3/P4 + RFC-0229: connector surface lane reading, acting,
   and per-person notes. *)
let shard_surface : shard =
  { name = "surface"
  ; tools = surface_tools
  ; read_only_tools = [ "keeper_surface_read" ]
  ; removable = true
  ; description = "Connected surfaces: read lane conversation, roster, person notes"
  }
;;

let shard_taskboard : shard =
  { name = "taskboard"
  ; tools = taskboard_tools
  ; read_only_tools = [ "keeper_tasks_list"; "keeper_tasks_audit" ]
  ; removable = true
  ; description =
      "Task board management: list, audit, claim, done, create, broadcast"
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

(** Default shards for a new keeper. *)
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
    ; shard_search_files
    ; shard_voice
    ; shard_library
    ; shard_surface
    ; shard_taskboard
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

   Built from [all_shards] plus unsharded default tools that must remain
   available without creating another capability-family shard. Retired GitHub
   Dedicated repository mutation schemas are intentionally excluded from this
   keeper-facing registry.

   Callers must still run [Config.dedupe_schemas] because a
   single tool can appear under multiple shards and the schema list may
   overlap with other roots (Tools.raw_schemas). *)
let all_keeper_tool_schemas : Masc_domain.tool_schema list =
  StringMap.fold (fun _name (shard : shard) acc -> shard.tools @ acc) all_shards []
  @ unsharded_default_tools
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
  @ unsharded_default_tools
;;


(** Re-exported from {!Tool_shard_schemas}. *)
let schemas = Tool_shard_schemas.schemas

(** {1 Removed MCP Execute Surface} *)

(** Legacy compatibility entrypoint. [masc_tool_*] callable tools are not
    exposed; shard membership is internal keeper policy state. *)
let execute (tool_name : string) (arguments : Yojson.Safe.t) : bool * Yojson.Safe.t =
  ignore arguments;
  false, `String ("Unknown tool: " ^ tool_name)
;;

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

(* tool_spec_read_only / tool_spec_destructive / tool_effect_domain moved to
   Tool_shard_types (intra-library file split,
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
            ?effect_domain:(tool_effect_domain s.name)
            ()))
    schemas
;;
