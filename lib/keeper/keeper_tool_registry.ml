(** Keeper tool runtime metadata and registered-schema injection. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let dedupe_tool_names names =
  dedupe_keep_order (names |> List.map String.trim |> List.filter (fun name -> name <> ""))
;;

(* RFC-0160 S7: raw command parsing is centralized in {!Exec_policy};
   word extraction is owned by {!Keeper_tool_command_words}. *)

let keeper_voice_tool_schemas =
  match Tool_shard.get_shard "voice" with
  | Some shard -> shard.tools
  | None -> []
;;

(* ── Read-only keeper tools ───────────────────────────────────── *)

(** Descriptor-projected read-only tools. This covers non-shard tools and
    descriptor-backed public/workspace tools without adding new string
    mirrors to the registry. *)
let descriptor_read_only_tools = Keeper_tool_descriptor.readonly_internal_names ()

let keeper_read_only_tools =
  Tool_shard.all_read_only_keeper_tools () @ descriptor_read_only_tools
  |> List.sort_uniq String.compare
;;

let keeper_read_only_lookup : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length keeper_read_only_tools) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) keeper_read_only_tools;
  tbl
;;

let is_keeper_read_only_tool (name : string) : bool =
  Hashtbl.mem keeper_read_only_lookup name
;;

let is_effectively_read_only_tool (name : string) : bool =
  (* Keeper-local check first (bare Hashtbl, no mutex) before
     descriptor-backed read-only lookup. Idempotency is a retry fact, not a
     substitute for read-only behavior. *)
  is_keeper_read_only_tool name
  || Keeper_tool_descriptor_resolution.capability_has Tool_capability.Read_only name
;;

let is_strictly_read_only_tool (name : string) : bool =
  is_effectively_read_only_tool name
;;

let has_mutating_side_effect (name : string) : bool =
  not (is_effectively_read_only_tool name)
;;

(* ── Input-aware read-only check ─────────────────────────────
   Some tools mix read-only and mutating subcommands within a single
   tool name. This function inspects JSON input where a live tool has
   such a contract. *)

let is_read_only_with_input ~(tool_name : string) ~(input : Yojson.Safe.t) : bool =
  match Keeper_tool_descriptor_resolution.readonly_for_tool_call ~tool_name ~input with
  | Some readonly -> readonly
  | None -> is_effectively_read_only_tool tool_name
;;

let is_strictly_read_only_with_input
      ~(tool_name : string)
      ~(input : Yojson.Safe.t)
  : bool
  =
  match Keeper_tool_descriptor_resolution.readonly_for_tool_call ~tool_name ~input with
  | Some readonly -> readonly
  | None -> is_strictly_read_only_tool tool_name
;;


(* ── Input-aware mutation-boundary bypass ────────────────────
   Removed: product-specific mutation-boundary bypasses do not belong in the
   generic tool registry. *)
(* ── Dynamic schema injection (masc_* tools) ──────────────────── *)

let masc_schemas_mutex = Stdlib.Mutex.create ()
let masc_schemas_state : Masc_domain.tool_schema list ref = ref []

let set_masc_schemas (schemas : Masc_domain.tool_schema list) =
  Stdlib.Mutex.protect masc_schemas_mutex (fun () -> masc_schemas_state := schemas)
;;

let masc_schemas_snapshot () =
  Stdlib.Mutex.protect masc_schemas_mutex (fun () -> !masc_schemas_state)
;;

let injected_masc_tool_names () =
  masc_schemas_snapshot ()
  |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
;;

(* ── keeper_tool_search schema ───────────────────────────────── *)

(** SSOT schema for keeper_tool_search.  Defined here because this is
    the keeper tool registry — the canonical owner of keeper-internal tool
    metadata. *)
let keeper_tool_search_schema : Masc_domain.tool_schema =
  { name = Keeper_tool_name.to_string Keeper_tool_name.Tool_search
  ; description =
      "Return the complete tool catalog already visible in this Keeper turn, \
       including exact names, descriptions, and input schemas."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; "properties", `Assoc []
        ; "required", `List []
        ]
  }
;;
