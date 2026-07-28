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
      "Search the tool schemas visible in this Keeper turn by free-text query. \
       Returns only the highest-ranked matching names, descriptions, and input \
       schemas."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "query"
                , `Assoc
                    [ "type", `String "string"
                    ; "description", `String "Search query for available Keeper tools."
                    ] )
              ; ( "max_results"
                , `Assoc
                    [ "type", `String "integer"
                    ; "minimum", `Int 1
                    ; "maximum", `Int 10
                    ; "default", `Int 5
                    ; ( "description"
                      , `String
                          "Maximum tool schemas to return. Default 5, capped at 10." )
                    ] )
              ] )
        ; "required", `List [ `String "query" ]
        ; "additionalProperties", `Bool false
        ]
  }
;;

type ranked_tool_schema =
  { schema : Masc_domain.tool_schema
  ; score : float
  }

let rank_tool_schemas ~query ~max_results schemas =
  let query = String.trim query in
  if String.equal query ""
  then []
  else
    let limit = Int.min 10 (Int.max 1 max_results) in
    schemas
    |> List.filter_map (fun (schema : Masc_domain.tool_schema) ->
      let search_document =
        String.concat
          "\n"
          [ schema.name
          ; schema.description
          ; Yojson.Safe.to_string schema.input_schema
          ]
      in
      let score =
        Text_similarity.jaccard_similarity query search_document
      in
      if Float.compare score 0.0 > 0
      then Some { schema; score }
      else None)
    |> List.sort (fun left right ->
      match Float.compare right.score left.score with
      | 0 -> String.compare left.schema.name right.schema.name
      | ordering -> ordering)
    |> List.filteri (fun index _ -> index < limit)
;;
