(** Tool definition and execution *)

open Types

(** Tool handler: Direct style (no Lwt) *)
type tool_handler = Yojson.Safe.t -> Types.tool_result

(** Context-aware tool handler *)
type context_tool_handler = Context.t -> Yojson.Safe.t -> Types.tool_result

module Execution_env = struct
  type t =
    { context : Context.t option
    ; invocation : Tool_contract.Invocation.t option
    }

  let create ?context ?invocation () = { context; invocation }
  let context t = t.context
  let invocation t = t.invocation
end

type execution_env_tool_handler = Execution_env.t -> Yojson.Safe.t -> Types.tool_result

type descriptor =
  | Ordinary_descriptor of Tool_contract.execution_mode
  | Terminal_descriptor of Tool_contract.failure_effect_disposition

let ordinary_descriptor execution_mode = Ordinary_descriptor execution_mode
let terminal_descriptor failure_effect = Terminal_descriptor failure_effect

let descriptor_execution_mode = function
  | Ordinary_descriptor execution_mode -> execution_mode
  | Terminal_descriptor _ -> Tool_contract.Serial
;;

let descriptor_completion = function
  | Ordinary_descriptor _ -> Tool_contract.Continue_after_success
  | Terminal_descriptor failure_effect ->
    Tool_contract.Terminal_after_success failure_effect
;;

type t =
  { schema : tool_schema
  ; descriptor : descriptor option
  ; handler : execution_env_tool_handler
  }

(* ── Handler adapters ─────────────────────────────────────────────
   Where the schema comes from and what the handler reads are independent
   axes. Naming one constructor per (source, kind) pair makes this surface
   their product, so every new handler kind owes one function per source and
   every new source owes one per kind. That product is what left the
   authoritative source reachable from only one of the three handler kinds.
   The adapters below keep the axes separate: a handler is converted once, and
   {!of_schema} is the single pairing function. *)

(** Adapt a handler that does not read the execution environment. *)
let ignoring_execution_env (handler : tool_handler) _execution_env input = handler input

(** Adapt a context-aware handler. Without a context there is nothing to pass,
    so the call fails rather than substituting an empty one. *)
let requiring_context (handler : context_tool_handler) execution_env input =
  match Execution_env.context execution_env with
  | Some context -> handler context input
  | None ->
    Error
      { message = "context-aware tool requires explicit context"
      ; recoverable = false
      ; error_class = Some Deterministic
      }
;;

(** Pair a schema with a handler. [Types.tool_schema] is [private] and each of
    its two constructors derives one argument view from the other, so a schema
    whose views disagree cannot reach this function — the invariant is carried
    by the type rather than re-encoded in a constructor's name. Every
    (schema source, handler kind) combination is this function applied to the
    schema constructor and the handler adapter for that combination. *)
let of_schema ?descriptor (schema : tool_schema) (handler : execution_env_tool_handler) =
  { schema; descriptor; handler }
;;

(** The (parameter view, plain handler) corner, which is most call sites.
    Exactly [of_schema (Types.tool_schema_of_params ...)
    (ignoring_execution_env handler)]. *)
let create ?descriptor ?strict ~name ~description ~parameters handler =
  of_schema
    ?descriptor
    (Types.tool_schema_of_params ?strict ~name ~description ~parameters ())
    (ignoring_execution_env handler)
;;

(** Execute a tool with its explicit execution resources. *)
let execute ?context ?invocation tool input =
  tool.handler (Execution_env.create ?context ?invocation ()) input
;;

let descriptor tool = tool.descriptor

let execution_mode tool =
  Option.fold ~none:Tool_contract.Serial ~some:descriptor_execution_mode tool.descriptor
;;

let completion tool =
  Option.fold
    ~none:Tool_contract.Continue_after_success
    ~some:descriptor_completion
    tool.descriptor
;;

let descriptor_to_yojson = function
  | None -> `Null
  | Some descriptor ->
    `Assoc
      [ ( "execution_mode"
        , Tool_contract.execution_mode_to_yojson (descriptor_execution_mode descriptor) )
      ; ( "completion"
        , Tool_contract.completion_to_yojson (descriptor_completion descriptor) )
      ]
;;

(** Schema to JSON *)
let schema_to_json tool =
  `Assoc
    ([ "name", `String tool.schema.name
     ; "description", `String tool.schema.description
       (* The authoritative schema goes to the provider verbatim. Deriving it
          back from [parameters] would drop minimum/maximum/default/enum and
          nested properties, which the model then never sees. *)
     ; ( "input_schema"
       , match tool.schema.input_schema with
         | Some schema -> schema
         | None -> Types.params_to_input_schema tool.schema.parameters )
     ]
     @
     match tool.schema.strict with
     | Some strict -> [ "strict", `Bool strict ]
     | None -> [])
;;

(** Wrap a tool to inject default arguments when not provided by the LLM.
    Defaults are merged into JSON object args before the handler runs. *)
let with_defaults (defaults : (string * Yojson.Safe.t) list) (tool : t) : t =
  let inject_defaults input =
    match input with
    | `Assoc fields ->
      let merged =
        List.fold_left
          (fun acc (k, v) -> if List.mem_assoc k acc then acc else (k, v) :: acc)
          fields
          defaults
      in
      `Assoc merged
    | other -> other
  in
  let handler execution_env input = tool.handler execution_env (inject_defaults input) in
  { tool with handler }
;;
