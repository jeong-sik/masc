(** Tool call middleware — reusable strict validation primitives.

    @since 0.101.0 *)

(* ── Pre-hook action type ─────────────────────────────────── *)

type pre_hook_action =
  | Pass
  | Reject of
      { is_error : bool
      ; message : string
      }

(* ── Validation convenience ───────────────────────────────── *)

let validate_input ~tool_name ~(schema : Types.tool_schema) args =
  match Tool_input_validation.validate schema args with
  | Tool_input_validation.Valid _ -> Pass
  | Tool_input_validation.Invalid errors ->
    let message = Tool_input_validation.format_errors_inline ~tool_name ~args errors in
    Reject { is_error = true; message }
;;

(* ── Schema conversion ────────────────────────────────────── *)

(* The caller's schema is kept as the authoritative wire form so its
   constraints survive to the provider; the constructor derives the parameter
   view from it, so the two views cannot disagree. *)
let tool_schema_of_json_result ~name ?(description = "") json_schema =
  Types.tool_schema_of_input_schema ~name ~description ~input_schema:json_schema ()
;;

let tool_schema_of_json ~name ?(description = "") json_schema : Types.tool_schema =
  match tool_schema_of_json_result ~name ~description json_schema with
  | Ok schema -> schema
  | Error detail -> invalid_arg detail
;;

(* ── Hook factory ─────────────────────────────────────────── *)

let make_validation_hook ~lookup =
  fun ~name ~args ->
  match lookup name with
  | None ->
    Reject
      { is_error = true
      ; message = Printf.sprintf "No schema registered for tool '%s'" name
      }
  | Some schema -> validate_input ~tool_name:name ~schema args
;;
