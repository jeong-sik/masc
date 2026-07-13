(** Keeper tool runtime metadata and registered-schema injection. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let dedupe_tool_names names =
  dedupe_keep_order (names |> List.map String.trim |> List.filter (fun name -> name <> ""))
;;

(* RFC-0160 S7: raw command parsing is centralized in {!Exec_policy};
   word extraction is owned by {!Keeper_tool_command_words}. *)

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
