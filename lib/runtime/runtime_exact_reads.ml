(* The five capabilities of its model an exact-output slot needs runtime.toml
   to state (RFC-0514 §2.2). A model the catalog has no row for is a slot only
   when runtime.toml states each of them; a provider preset never stands in
   for one of these five. *)

type t =
  | Context_window
  | Reasoning_effort_ladder
  | Json_mode
  | Native_schema
  | Output_ceiling

let key = function
  | Context_window -> "max-context"
  | Reasoning_effort_ladder -> "capabilities.accepted-reasoning-efforts"
  | Json_mode -> "capabilities.supports-response-format-json"
  | Native_schema -> "capabilities.supports-structured-output"
  | Output_ceiling -> "capabilities.max-output-tokens"
;;

type stated =
  { context_window : int
  ; reasoning_effort_ladder : Llm_provider.Reasoning_effort.t list
  ; json_mode : bool
  ; native_schema : bool
  ; output_ceiling : int
  }

(* Both values, or every read either side leaves unstated, the left side's
   first. *)
let both left right =
  match left, right with
  | Ok left, Ok right -> Ok (left, right)
  | Ok _, Error unstated | Error unstated, Ok _ -> Error unstated
  | Error (first, rest), Error (next, more) -> Error (first, rest @ (next :: more))
;;

let parse (rt : Runtime_instance.t) =
  let table = rt.Runtime_instance.model.Runtime_schema.capabilities in
  let from_table read field =
    match Option.bind table field with
    | Some value -> Ok value
    | None -> Error (read, [])
  in
  (* The window the runtime resolves, so a binding, provider or model
     [max-context] counts where it applies. One only the capability catalog
     answers is the preset's or the row's, and one the catalog's window
     clamped runs as the catalog's: neither is what runtime.toml states. *)
  let context_window =
    match Runtime_instance.resolve_max_context_of_runtime rt with
    | Some
        ( tokens
        , ( Runtime_instance.Override
          | Runtime_instance.Provider_override
          | Runtime_instance.Binding_override ) ) -> Ok tokens
    | Some
        ( (_ : int)
        , ( Runtime_instance.Capability
          | Runtime_instance.Override_clamped_by_capability
          | Runtime_instance.Provider_override_clamped_by_capability
          | Runtime_instance.Binding_override_clamped_by_capability ) )
    | None -> Error (Context_window, [])
  in
  (* The parser reads an empty list as unwritten; so does this. *)
  let reasoning_effort_ladder =
    match
      Option.bind table (fun (caps : Runtime_schema.model_capabilities) ->
        caps.accepted_reasoning_efforts)
    with
    | Some (_ :: _ as ladder) -> Ok ladder
    | Some [] | None -> Error (Reasoning_effort_ladder, [])
  in
  let json_mode =
    from_table Json_mode (fun (caps : Runtime_schema.model_capabilities) ->
      caps.supports_response_format_json)
  in
  let native_schema =
    from_table Native_schema (fun (caps : Runtime_schema.model_capabilities) ->
      caps.supports_structured_output)
  in
  let output_ceiling =
    from_table Output_ceiling (fun (caps : Runtime_schema.model_capabilities) ->
      caps.max_output_tokens)
  in
  match
    both
      context_window
      (both reasoning_effort_ladder (both json_mode (both native_schema output_ceiling)))
  with
  | Ok (context_window, (reasoning_effort_ladder, (json_mode, (native_schema, output_ceiling))))
    -> Ok { context_window; reasoning_effort_ladder; json_mode; native_schema; output_ceiling }
  | Error unstated -> Error unstated
;;

let capabilities_over ~(base : Llm_provider.Capabilities.capabilities) stated =
  { base with
    max_context_tokens = Some stated.context_window
  ; accepted_reasoning_efforts = Some stated.reasoning_effort_ladder
  ; supports_response_format_json = stated.json_mode
  ; supports_structured_output = stated.native_schema
  ; max_output_tokens = Some stated.output_ceiling
  }
;;
