(* RFC-0057 Phase 2 — spec types extracted into a standalone library.

   Why standalone? The generator executable (bin/gen_tool_descriptors.ml)
   must not depend on masc_tool_schemas (the consumer of the generated
   file), otherwise dune sees a cycle: exe -> lib -> generated file -> exe.

   Keeping these types in a tiny sibling library breaks the cycle:
   exe depends on tool_schemas_specs (types only), and masc_tool_schemas
   depends on nothing new — it just receives the generated ml. *)

type param_type =
  | T_string of
      { enum : string list option
      ; default : string option
      }
  | T_int of
      { min : int option
      ; max : int option
      ; default : int option
      }
  | T_bool of { default : bool option }

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
