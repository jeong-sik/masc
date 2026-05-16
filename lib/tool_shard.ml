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

(* coding_keeper_bridge_tools schema list moved to Tool_shard_types. *)
(** Pre-flight validation for keeper autonomous work. *)
(** PR review tools — read diffs, leave comments, approve/request changes. *)
(* keeper_preflight_tools + keeper_github_pr_tools schema lists moved to Tool_shard_types. *)

(* keeper_pr_review_tools schema list moved to Tool_shard_types. *)

(* coding_workspace_tools / coding_tools / voice_tools / library_tools /
   taskboard_tools schema lists moved to Tool_shard_types. *)
(* shard_* records + autoresearch_keeper_tools moved to Tool_shard_types. *)
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

(* all_shards + accessors + grant/revoke moved to Tool_shard_types. *)
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
