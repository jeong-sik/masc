(* RFC-0057 Phase 1 — tool descriptor codegen.

   Mirrors bin/gen_shell_ir_walkers.ml: spec-as-OCaml-value -> Buffer.emit
   -> stdout. The dune rule in lib/tool_schemas/ captures stdout into
   tool_descriptors_gen.ml inside the masc_tool_schemas library, so the
   generated schemas live alongside the hand-written ones in the same
   module namespace.

   Phase 1 scope: masc_config + masc_code_read. The regression test
   (test/test_tool_descriptors_gen.ml) compares emitted schemas against
   hand-written ones field-by-field on Yojson values. tool_schemas_misc.ml
   drops the hand-written masc_config entry and concatenates
   Tool_descriptors_gen.schemas so generated schemas are the SSOT.

   Why self-contained (no library deps)?
   bin/gen_shell_ir_walkers.ml (RFC-0054 PR-3) sets the precedent: the
   generator carries its own spec to avoid a dune cycle between
   (executable) and (library) when the library would consume the
   generated file. Phase 2 lifts the spec records into a sibling
   library lib/tool_schemas_specs/ once a 3rd tool lands. *)

(* === Spec types (local; will move to lib/tool_schemas_specs in Phase 1). *)

type param_type =
  | T_string of { enum : string list option }
  | T_int of { min : int option; max : int option }
  | T_bool

type param =
  { p_name : string
  ; p_type : param_type
  ; p_description : string
  ; p_required : bool
  }

type tool_spec =
  { name : string
  ; description : string
  ; parameters : param list
  ; additional_properties : bool
  }

(* === Phase 0 spec data ==============================================

   masc_config — single optional `category` filter. The enum mirrors
   Tool_schemas_misc.config_category_enum_strings (Issue #8493). Phase
   0 keeps a third copy in this generator to stay self-contained; the
   regression test guarantees this copy stays aligned with the
   hand-written schema, and Phase 1 collapses all three into a typed
   SSOT. *)

let config_category_enum_strings =
  [ "server"; "auth"; "transport"; "storage"; "runtime"
  ; "rate_limiting"; "inference"; "keeper"; "keeper_execution"
  ; "keeper_guardrails"; "autonomy"; "level2"; "dashboard"
  ; "economy"; "governance"; "channel"; "process"; "worker"
  ; "web_search"; "session"
  ]

let masc_config_spec : tool_spec =
  { name = "masc_config"
  ; description =
      "Return the effective runtime configuration with source attribution (env var or default) for each setting. \
Sensitive values (tokens, passwords) are masked. Use to inspect or verify the server config without restarting. \
Pass category to filter results to a single section."
  ; parameters =
      [ { p_name = "category"
        ; p_type = T_string { enum = Some config_category_enum_strings }
        ; p_description = "Filter by config category"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }

let masc_code_read_spec : tool_spec =
  { name = "masc_code_read"
  ; description =
      "Read a file with offset/limit pagination for large files. \
Use when inspecting source code during task execution without loading the entire file into context."
  ; parameters =
      [ { p_name = "path"
        ; p_type = T_string { enum = None }
        ; p_description = "Absolute file path"
        ; p_required = true
        }
      ; { p_name = "offset"
        ; p_type = T_int { min = Some 0; max = None }
        ; p_description = "Offset in bytes (default 0)"
        ; p_required = false
        }
      ; { p_name = "limit"
        ; p_type = T_int { min = Some 1; max = Some 1_000_000 }
        ; p_description = "Maximum bytes to read (default 1_000_000)"
        ; p_required = false
        }
      ]
  ; additional_properties = false
  }

let phase1_specs : tool_spec list = [ masc_config_spec; masc_code_read_spec ]

(* === Emit helpers ==================================================== *)

let buf_addf buf fmt = Printf.ksprintf (Buffer.add_string buf) fmt

let emit_header buf =
  Buffer.add_string buf
    "(* GENERATED - DO NOT EDIT.\n\
    \   Source: bin/gen_tool_descriptors.ml (RFC-0057 Phase 1).\n\
    \   To regenerate: dune build *)\n\
     \n\
     open Masc_domain\n\
     \n"

let emit_enum_list buf strings =
  Buffer.add_string buf "`List [";
  List.iteri (fun i s ->
    if i > 0 then Buffer.add_string buf "; ";
    buf_addf buf "`String %S" s
  ) strings;
  Buffer.add_string buf "]"

let emit_param_property buf p =
  let type_label = match p.p_type with
    | T_string _ -> "string"
    | T_int _ -> "integer"
    | T_bool -> "boolean"
  in
  buf_addf buf "        (%S, `Assoc [\n" p.p_name;
  buf_addf buf "          (\"type\", `String %S);\n" type_label;
  (match p.p_type with
   | T_string { enum = Some strings } ->
     Buffer.add_string buf "          (\"enum\", ";
     emit_enum_list buf strings;
     Buffer.add_string buf ");\n"
   | _ -> ());
  buf_addf buf "          (\"description\", `String %S);\n" p.p_description;
  Buffer.add_string buf "        ]);\n"

let emit_required buf params =
  let req = List.filter_map
    (fun p -> if p.p_required then Some p.p_name else None) params
  in
  match req with
  | [] -> ()
  | _ ->
    Buffer.add_string buf "      (\"required\", `List [";
    List.iteri (fun i name ->
      if i > 0 then Buffer.add_string buf "; ";
      buf_addf buf "`String %S" name
    ) req;
    Buffer.add_string buf "]);\n"

let emit_tool_schema buf spec =
  Buffer.add_string buf "  {\n";
  buf_addf buf "    name = %S;\n" spec.name;
  buf_addf buf "    description = %S;\n" spec.description;
  Buffer.add_string buf "    input_schema = `Assoc [\n";
  Buffer.add_string buf "      (\"type\", `String \"object\");\n";
  (match spec.parameters with
   | [] ->
     Buffer.add_string buf "      (\"properties\", `Assoc []);\n"
   | params ->
     Buffer.add_string buf "      (\"properties\", `Assoc [\n";
     List.iter (emit_param_property buf) params;
     Buffer.add_string buf "      ]);\n");
  emit_required buf spec.parameters;
  buf_addf buf "      (\"additionalProperties\", `Bool %b);\n"
    spec.additional_properties;
  Buffer.add_string buf "    ];\n";
  Buffer.add_string buf "  };\n"

let emit_schemas_list buf specs =
  Buffer.add_string buf "let schemas : tool_schema list = [\n";
  List.iter (emit_tool_schema buf) specs;
  Buffer.add_string buf "]\n"

(* === Entry point ===================================================== *)

let () =
  let buf = Buffer.create 4096 in
  emit_header buf;
  emit_schemas_list buf phase1_specs;
  print_string (Buffer.contents buf)
