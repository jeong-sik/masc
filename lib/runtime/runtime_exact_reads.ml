(* The capabilities an exact-output slot reads from its model (RFC-0514 §2.2).
   A model the catalog has no row for is a slot only when runtime.toml states
   each of them; a provider preset never stands in for one. *)

type t =
  | Context_window
  | Reasoning_effort_ladder
  | Json_mode
  | Native_schema

let all = [ Context_window; Reasoning_effort_ladder; Json_mode; Native_schema ]

let key = function
  | Context_window -> "max-context"
  | Reasoning_effort_ladder -> "capabilities.accepted-reasoning-efforts"
  | Json_mode -> "capabilities.supports-response-format-json"
  | Native_schema -> "capabilities.supports-structured-output"
;;

let stated (rt : Runtime_instance.t) read =
  let table = rt.Runtime_instance.model.Runtime_schema.capabilities in
  match read with
  (* The window the runtime resolves, so a binding, provider or model
     [max-context] counts where it applies. A window only the capability
     catalog answers is the preset's or the row's, not runtime.toml's. *)
  | Context_window ->
    (match Runtime_instance.resolve_max_context_of_runtime rt with
     | Some
         ( (_ : int)
         , ( Runtime_instance.Override
           | Runtime_instance.Override_clamped_by_capability
           | Runtime_instance.Provider_override
           | Runtime_instance.Provider_override_clamped_by_capability
           | Runtime_instance.Binding_override
           | Runtime_instance.Binding_override_clamped_by_capability ) ) -> true
     | Some ((_ : int), Runtime_instance.Capability) | None -> false)
  (* The parser reads an empty list as unwritten. *)
  | Reasoning_effort_ladder ->
    Option.is_some
      (Option.bind table (fun (caps : Runtime_schema.model_capabilities) ->
         caps.accepted_reasoning_efforts))
  | Json_mode ->
    Option.is_some
      (Option.bind table (fun (caps : Runtime_schema.model_capabilities) ->
         caps.supports_response_format_json))
  | Native_schema ->
    Option.is_some
      (Option.bind table (fun (caps : Runtime_schema.model_capabilities) ->
         caps.supports_structured_output))
;;

let unstated rt = List.filter (fun read -> not (stated rt read)) all
