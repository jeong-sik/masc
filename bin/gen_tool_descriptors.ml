(* RFC-0057 Phase 2 — tool descriptor codegen.

   Mirrors bin/gen_shell_ir_walkers.ml: spec-as-OCaml-value -> Buffer.emit
   -> stdout. The dune rule in lib/tool_schemas/ captures stdout into
   tool_descriptors_gen.ml inside the masc_tool_schemas library, so the
   generated schemas live alongside the hand-written ones in the same
   module namespace.

   Phase 2 lifted spec types into lib/tool_schemas_specs/ to share
   between the generator and any future tooling (schema lint, doc
   generation). The executable now depends on tool_schemas_specs (types
   only), avoiding the cycle because that library does not depend on
   masc_tool_schemas. *)

open Tool_schemas_specs_types

(* === Phase 0 spec data ==============================================

   masc_config — single optional `category` filter. The enum mirrors
   Tool_schemas_misc.config_category_enum_strings (Issue #8493). Phase
   0 keeps a third copy in this generator to stay self-contained; the
   regression test guarantees this copy stays aligned with the
   hand-written schema, and Phase 1 collapses all three into a typed
   SSOT. *)

let config_category_enum_strings =
  [ "server"
  ; "auth"
  ; "transport"
  ; "storage"
  ; "runtime"
  ; "rate_limiting"
  ; "inference"
  ; "keeper"
  ; "keeper_execution"
  ; "keeper_guardrails"
  ; "autonomy"
  ; "level2"
  ; "dashboard"
  ; "economy"
  ; "governance"
  ; "channel"
  ; "process"
  ; "worker"
  ; "web_search"
  ; "session"
  ]
;;

let masc_config_spec : tool_spec =
  { name = "masc_config"
  ; description =
      "Return the effective runtime configuration with source attribution (env var or \
       default) for each setting. Sensitive values (tokens, passwords) are masked. Use \
       to inspect or verify the server config without restarting. Pass category to \
       filter results to a single section."
  ; parameters =
      [ { p_name = "category"
        ; p_type = T_string { enum = Some config_category_enum_strings; default = None }
        ; p_description = "Filter by config category"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_code_read_spec : tool_spec =
  { name = "masc_code_read"
  ; description =
      "Read a file with offset/limit pagination for large files. Use when inspecting \
       source code during task execution without loading the entire file into context."
  ; parameters =
      [ { p_name = "path"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Absolute file path"
        ; p_required = true
        }
      ; { p_name = "offset"
        ; p_type = T_int { min = Some 0; max = None; default = None }
        ; p_description = "Offset in bytes (default 0)"
        ; p_required = false
        }
      ; { p_name = "limit"
        ; p_type = T_int { min = Some 1; max = Some 1_000_000; default = None }
        ; p_description = "Maximum bytes to read (default 1_000_000)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_tool_help_spec : tool_spec =
  { name = "masc_tool_help"
  ; description =
      "Return canonical help text, parameters, and metadata for a specific MASC tool by \
       name."
  ; parameters =
      [ { p_name = "tool_name"
        ; p_type = T_string { enum = None; default = None }
        ; p_description = "Exact MCP tool name to explain"
        ; p_required = true
        }
      ]
  ; additional_properties = false
  }
;;

let dashboard_scope_enum_strings = [ "all"; "current" ]

let masc_dashboard_spec : tool_spec =
  { name = "masc_dashboard"
  ; description =
      "Render the MASC dashboard summarizing rooms, agents, and tasks. Set \
       scope='current' for this room only."
  ; parameters =
      [ { p_name = "compact"
        ; p_type = T_bool { default = None }
        ; p_description =
            "If true, show compact single-line summary instead of full dashboard"
        ; p_required = false
        }
      ; { p_name = "scope"
        ; p_type =
            T_string { enum = Some dashboard_scope_enum_strings; default = Some "all" }
        ; p_description = "Dashboard scope (default: all)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let masc_gc_spec : tool_spec =
  { name = "masc_gc"
  ; description =
      "Run garbage collection: remove zombie agents, archive stale tasks, delete old \
       messages (default: 7-day threshold)."
  ; parameters =
      [ { p_name = "days"
        ; p_type = T_int { min = None; max = None; default = Some 7 }
        ; p_description = "Age threshold in days (default: 7)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }
;;

let phase3_specs : tool_spec list =
  [ masc_config_spec
  ; masc_code_read_spec
  ; masc_tool_help_spec
  ; masc_dashboard_spec
  ; masc_gc_spec
  ]
;;

(* === Emit helpers ==================================================== *)

let buf_addf buf fmt = Printf.ksprintf (Buffer.add_string buf) fmt

let emit_header buf =
  Buffer.add_string
    buf
    "(* GENERATED - DO NOT EDIT.\n\
    \   Source: bin/gen_tool_descriptors.ml (RFC-0057 Phase 1).\n\
    \   To regenerate: dune build *)\n\n\
     open Masc_domain\n\n"
;;

let emit_enum_list buf strings =
  Buffer.add_string buf "`List [";
  List.iteri
    (fun i s ->
       if i > 0 then Buffer.add_string buf "; ";
       buf_addf buf "`String %S" s)
    strings;
  Buffer.add_string buf "]"
;;

let emit_param_property buf p =
  let type_label =
    match p.p_type with
    | T_string _ -> "string"
    | T_int _ -> "integer"
    | T_bool _ -> "boolean"
  in
  buf_addf buf "        (%S, `Assoc [\n" p.p_name;
  buf_addf buf "          (\"type\", `String %S);\n" type_label;
  (match p.p_type with
   | T_string { enum = Some strings; _ } ->
     Buffer.add_string buf "          (\"enum\", ";
     emit_enum_list buf strings;
     Buffer.add_string buf ");\n"
   | _ -> ());
  buf_addf buf "          (\"description\", `String %S);\n" p.p_description;
  (match p.p_type with
   | T_string { default = Some d; _ } ->
     buf_addf buf "          (\"default\", `String %S);\n" d
   | T_int { default = Some d; _ } -> buf_addf buf "          (\"default\", `Int %d);\n" d
   | T_bool { default = Some d; _ } ->
     buf_addf buf "          (\"default\", `Bool %b);\n" d
   | _ -> ());
  Buffer.add_string buf "        ]);\n"
;;

let emit_required buf params =
  let req =
    List.filter_map (fun p -> if p.p_required then Some p.p_name else None) params
  in
  match req with
  | [] -> ()
  | _ ->
    Buffer.add_string buf "      (\"required\", `List [";
    List.iteri
      (fun i name ->
         if i > 0 then Buffer.add_string buf "; ";
         buf_addf buf "`String %S" name)
      req;
    Buffer.add_string buf "]);\n"
;;

let emit_tool_schema buf spec =
  Buffer.add_string buf "  {\n";
  buf_addf buf "    name = %S;\n" spec.name;
  buf_addf buf "    description = %S;\n" spec.description;
  Buffer.add_string buf "    input_schema = `Assoc [\n";
  Buffer.add_string buf "      (\"type\", `String \"object\");\n";
  (match spec.parameters with
   | [] -> Buffer.add_string buf "      (\"properties\", `Assoc []);\n"
   | params ->
     Buffer.add_string buf "      (\"properties\", `Assoc [\n";
     List.iter (emit_param_property buf) params;
     Buffer.add_string buf "      ]);\n");
  emit_required buf spec.parameters;
  buf_addf buf "      (\"additionalProperties\", `Bool %b);\n" spec.additional_properties;
  Buffer.add_string buf "    ];\n";
  Buffer.add_string buf "  };\n"
;;

let emit_schemas_list buf specs =
  Buffer.add_string buf "let schemas : tool_schema list = [\n";
  List.iter (emit_tool_schema buf) specs;
  Buffer.add_string buf "]\n"
;;

(* === Entry point ===================================================== *)

let () =
  let buf = Buffer.create 4096 in
  emit_header buf;
  emit_schemas_list buf phase3_specs;
  print_string (Buffer.contents buf)
;;
