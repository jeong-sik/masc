(** Tool_input_validation — Pre-dispatch JSON Schema validation for MCP tools.

    Validates tool call arguments against their declared input_schema before
    the tool handler executes. Catches missing required fields and basic type
    mismatches that would otherwise cause silent failures (default "" substitution)
    or runtime exceptions deep in handler code.

    Scope (intentionally limited):
    - Required field presence check
    - Top-level property type validation (string, integer, number, boolean, array, object)
    - Does NOT validate: nested schemas, enums, patterns, min/max bounds

    Registered as a Tool_dispatch pre-hook at server startup.
    When validation fails, the tool call is rejected with a descriptive error
    before any side effects occur.

    @since 2.150.0 — C-4 ecosystem audit *)

(* ================================================================ *)
(* JSON Schema type checking                                         *)
(* ================================================================ *)

(** Check if a JSON value matches the declared type string.
    Follows JSON Schema draft-07 type keywords. *)
let value_matches_type (value : Yojson.Safe.t) (type_str : string) : bool =
  match type_str with
  | "string" -> (match value with `String _ -> true | _ -> false)
  | "integer" -> (match value with `Int _ -> true | `Intlit _ -> true | _ -> false)
  | "number" ->
    (match value with
     | `Float _ | `Int _ | `Intlit _ -> true
     | _ -> false)
  | "boolean" -> (match value with `Bool _ -> true | _ -> false)
  | "array" -> (match value with `List _ -> true | _ -> false)
  | "object" -> (match value with `Assoc _ -> true | _ -> false)
  | "null" -> (match value with `Null -> true | _ -> false)
  | _ -> true  (* Unknown type keyword — permissive, don't block *)

(** Human-readable type name for a JSON value. *)
let type_name_of (value : Yojson.Safe.t) : string =
  match value with
  | `String _ -> "string"
  | `Int _ | `Intlit _ -> "integer"
  | `Float _ -> "number"
  | `Bool _ -> "boolean"
  | `List _ -> "array"
  | `Assoc _ -> "object"
  | `Null -> "null"

(* ================================================================ *)
(* Validation engine                                                 *)
(* ================================================================ *)

(** Validate tool arguments against a JSON Schema input_schema.

    Returns Ok () on success, Error message on first validation failure.
    Checks are ordered: required fields first, then type checks.

    @param tool_name Used only for error messages
    @param schema The input_schema from tool_schema (JSON Schema object)
    @param args The actual arguments passed to the tool call *)
let validate ~(tool_name : string) ~(schema : Yojson.Safe.t)
    ~(args : Yojson.Safe.t) : (unit, string) result =
  let open Yojson.Safe.Util in
  (* Only validate object-type schemas *)
  let schema_type =
    try schema |> member "type" |> to_string
    with Type_error _ -> "object"
  in
  if schema_type <> "object" then Ok ()
  else
    (* Extract properties and required list from schema *)
    let properties =
      try
        match schema |> member "properties" with
        | `Assoc props -> props
        | _ -> []
      with Type_error _ -> []
    in
    let required =
      try
        match schema |> member "required" with
        | `List items ->
          List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> []
      with Type_error _ -> []
    in
    let arg_fields =
      match args with
      | `Assoc fields -> fields
      | `Null -> []  (* Allow null as empty args — common for no-arg tools *)
      | _ -> []      (* Non-object args: will fail required check if any exist *)
    in
    (* 1. Check required fields *)
    let missing =
      List.filter (fun key ->
        not (List.mem_assoc key arg_fields)
      ) required
    in
    if missing <> [] then
      Error (Printf.sprintf "%s: missing required field(s): %s"
        tool_name (String.concat ", " missing))
    else
      (* 2. Type-check provided fields against property schemas *)
      let type_errors =
        List.filter_map (fun (key, value) ->
          match List.assoc_opt key properties with
          | None -> None  (* Extra fields allowed — open schema *)
          | Some prop_schema ->
            let expected_type =
              try
                match prop_schema |> member "type" with
                | `String t -> Some t
                | _ -> None
              with Type_error _ -> None
            in
            (match expected_type with
             | None -> None  (* No type declared — skip *)
             | Some t ->
               if value_matches_type value t then None
               else
                 Some (Printf.sprintf "'%s' expected %s, got %s"
                   key t (type_name_of value)))
        ) arg_fields
      in
      if type_errors <> [] then
        Error (Printf.sprintf "%s: type mismatch: %s"
          tool_name (String.concat "; " type_errors))
      else
        Ok ()

(* ================================================================ *)
(* Pre-hook registration                                             *)
(* ================================================================ *)

(** Register input validation as a Tool_dispatch pre-hook.
    Must be called after all tool schemas are registered (server init).

    When validation fails, returns a Tool_result error that short-circuits
    tool execution — the handler never runs and no side effects occur.

    Tools without a registered schema are allowed through (permissive). *)
let register_pre_hook () =
  Tool_dispatch.register_pre_hook (fun ~name ~args ->
    match Tool_dispatch.lookup_schema name with
    | None -> None  (* No schema registered — allow *)
    | Some schema ->
      match validate ~tool_name:name ~schema ~args with
      | Ok () -> None  (* Validation passed — proceed to handler *)
      | Error msg ->
        Log.info "tool_input_validation rejected %s: %s" name msg;
        Some { Tool_result.
          success = false;
          data = `Assoc [
            ("error", `String msg);
            ("validation", `String "input_schema_precondition");
          ];
          tool_name = name;
          duration_ms = 0.0;
        })
