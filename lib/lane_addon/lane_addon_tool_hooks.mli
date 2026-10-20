(** Selected, immutable middleware for one worker's exact advertised tool.
    Hooks validate without rewriting arguments or results and never retry calls.
    Schemas use the explicit subset accepted by [Lane_addon_action], not arbitrary
    JSON Schema. Unsupported declarations fail before the tool is published. *)
type hook = Lane_addon_types.tool_hook = Validate_input | Validate_output
val hook_name : hook -> string
val hook_of_string : string -> hook option
val selection_of_json : Yojson.Safe.t -> (hook list, string) result
type t
val prepare : hooks:hook list -> Mcp_protocol.Mcp_types.tool -> (t, string) result
val before_call : t -> Yojson.Safe.t -> (unit, string) result
val after_call : t -> Mcp_protocol.Mcp_types.tool_result -> (unit, string) result
(** Error replies retain their original failure/effect metadata. Only successful
    replies require [structuredContent] matching the selected output contract.
    A rejected successful reply is an unknown effect, never a pre-effect refusal. *)
