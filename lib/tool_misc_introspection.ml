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

(** Tool_misc_introspection — config and tool inventory handlers.

    Extracted from tool_misc.ml to reduce god file size.
    Contains read-only dashboard config and catalog inventory helpers.

    @since 2.187.0 — God file decomposition Phase 1 *)

open Tool_args

type tool_result = Tool_result.result

(* ================================================================ *)
(* JSON builders                                                    *)
(* ================================================================ *)

let tool_inventory_json _ctx ~include_hidden =
  (* Returns all tool schemas from catalog with metadata.
     enabled_in_current_mode=false because this is dashboard context (no keeper).
     Keeper model visibility is the complete descriptor-declared surface. *)
  let surface_map : (string, string list) Hashtbl.t = Hashtbl.create 256 in
  let add_surface name s =
    let prev =
      match Hashtbl.find_opt surface_map name with Some l -> l | None -> []
    in
    if not (List.mem s prev) then Hashtbl.replace surface_map name (s :: prev)
  in
  (* The per-actor [surfaces_for_tool] contribution was dropped in the
     surface-cut refactor (the [surface] type is deleted).  Tool visibility is
     now reported via the public_mcp projection below plus the
     Capability_registry projection seeds. *)
  Config.raw_all_tool_schemas
  |> List.iter (fun (schema : Masc_domain.tool_schema) ->
         if Tool_catalog.is_public_mcp schema.name then
           add_surface schema.name "public_mcp");
  List.iter
    (fun (seed : Capability_registry.capability_seed) ->
      let s = Capability_registry.surface_to_string seed.projection.surface in
      if not (String.equal s "public_mcp") then (
        add_surface seed.projection.tool_name s;
        add_surface seed.projection.backend_tool_name s))
    (Capability_registry.all_projection_seeds_from Config.raw_all_tool_schemas);
  let schemas =
    Config.raw_all_tool_schemas
    |> List.filter (fun (schema : Masc_domain.tool_schema) ->
           Tool_catalog.is_visible ~include_hidden schema.name)
    |> List.sort (fun (left : Masc_domain.tool_schema) right -> String.compare left.name right.name)
  in
  let rows =
    schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) ->
           let help_entry = Tool_help_registry.entry_of_schema schema in
           (* [metadata_to_fields] no longer emits a per-actor "surfaces" key
              (surface type deleted); the local [surface_map] below owns the
              tool's "surfaces" field. *)
           let metadata_fields = Tool_catalog.metadata_to_fields schema.name in
           `Assoc
             ([
                ("name", `String schema.name);
                ("description", `String help_entry.short_description);
                ("registered_schema", `Bool true);
                ( "dispatch_registered",
                  `Bool (Option.is_some (Tool_dispatch.lookup_tag schema.name)) );
                ("enabled_in_current_mode", `Bool false);
                ("direct_call_allowed", `Bool (Tool_catalog.allow_direct_call schema.name));
                ("doc_refs", `List (List.map (fun value -> `String value) help_entry.doc_refs));
                ("prompt_hints", `List (List.map (fun value -> `String value) help_entry.prompt_hints));
                ("surfaces",
                 `List
                   (match Hashtbl.find_opt surface_map schema.name with
                   | Some ss -> List.map (fun s -> `String s) (List.rev ss)
                   | None -> []));
              ]
             @ metadata_fields))
  in
  `Assoc
    [
      ("count", `Int (List.length rows));
      ("tools", `List rows);
      ("surface_summary",
       Capability_registry.surface_snapshot_json Config.raw_all_tool_schemas);
    ]

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

(* TEL-OK: read-only config introspection; tool-call telemetry is emitted by
   the shared dispatch wrapper, and this handler only formats Env_config JSON. *)
let handle_config ~tool_name ~start_time args : tool_result =
  let cat = get_string_opt args "category" in
  let json = Env_config_introspect.to_json_filtered ?cat () in
  Tool_result.make_ok ~tool_name ~start_time ~data:json ()
;;
