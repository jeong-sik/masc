(** Tool_input_validation — Pre-dispatch validation via OAS Tool_input_validation.

    Delegates to [Agent_sdk.Tool_input_validation] for type coercion and
    structured error feedback. Converts MASC JSON Schema to OAS [tool_schema]
    using [Tool_bridge.params_of_json_schema].

    Coercion examples (Samchon Harness Rank 1):
    - ["42"] (string) -> [42] (integer)
    - ["true"] (string) -> [true] (boolean)
    - [Intlit "123"] -> [Int 123]

    Registered as a Tool_dispatch pre-hook at server startup.
    When validation fails, returns structured field-level errors.

    @since 2.220.0 — OAS delegation (replaces custom validator) *)

(** Register input validation as a Tool_dispatch pre-hook.
    Must be called after all tool schemas are registered (server init).

    Tools without a registered schema are allowed through (permissive). *)
let register_pre_hook () =
  Tool_dispatch.register_pre_hook (fun ~name ~args ->
    match Tool_dispatch.lookup_schema name with
    | None -> Pass
    | Some json_schema ->
      let parameters = Tool_bridge.params_of_json_schema json_schema in
      if parameters = [] then Pass
      else
        let schema : Agent_sdk.Types.tool_schema =
          { name; description = ""; parameters }
        in
        match Agent_sdk.Tool_input_validation.validate schema args with
        | Agent_sdk.Tool_input_validation.Valid coerced ->
          if Yojson.Safe.equal coerced args then Pass
          else begin
            Log.info "tool_input_validation coerced args for %s" name;
            Proceed coerced
          end
        | Agent_sdk.Tool_input_validation.Invalid errors ->
          let msg =
            Agent_sdk.Tool_input_validation.format_errors ~tool_name:name errors
          in
          Log.info "tool_input_validation rejected %s: %s" name msg;
          Reject {
            Tool_result.success = false;
            data = `Assoc [
              ("error", `String msg);
              ("validation", `String "oas_tool_input_validation");
            ];
            tool_name = name;
            duration_ms = 0.0;
          })
