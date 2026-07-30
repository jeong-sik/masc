module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** OAS boundary adapter for tool results, schemas, and tool definitions.

    MASC dispatch uses typed [Tool_result.result] internally.  This module is the
    boundary adapter that converts typed MASC results to/from
    [Agent_sdk.Types.tool_result = (tool_output, tool_error) Result.t].

    Central [Tool_dispatch.handler] implementations should return
    [Tool_result.result] directly rather than reintroducing tuple dispatch.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + OAS Tool.t creation
    @since 2.??? — externalize large outputs via [Tool_blob_store] *)

(** {1 Tool Output Externalization}

    Tool outputs above [default_externalize_threshold_bytes] are stored
    in the content-addressed blob store ([Tool_blob_store]) and the
    OAS [content] field carries a blob marker
    ([Tool_output.encode_for_oas (Stored {...})]). Smaller outputs flow
    through unchanged.

    Stored results remain content-addressed references at the durable and
    provider boundaries. Their exact bytes remain available from the artifact
    store and HTTP artifact route without expanding every later model request.

    Disabled when [MASC_BASE_PATH] is unset (no store root resolvable),
    which keeps unit tests free from filesystem side effects unless they
    explicitly opt in. *)

let default_externalize_threshold_bytes = 2048

type externalization_error = { message : string }

let resolve_blob_store ?base_path () =
  let base_path =
    match base_path with
    | Some _ as explicit -> explicit
    | None -> (Host_config.from_env ()).base_path
  in
  match base_path with
  | None -> None
  | Some base_path -> Some (Tool_blob_store.create ~base_path)

(** Externalize [msg] when it exceeds the threshold and a blob store is
    available; otherwise pass through unchanged. A configured store that
    cannot persist the bytes returns a typed error: putting the oversized
    payload back on the provider wire would defeat this boundary. *)
let maybe_externalize ?base_path ?(mime = "text/plain") (msg : string)
  : (string, externalization_error) result
  =
  if String.length msg <= default_externalize_threshold_bytes then Ok msg
  else
    match resolve_blob_store ?base_path () with
    | None -> Ok msg
    | Some store ->
        (try
           let reference =
             Tool_blob_store.put_durable store ~bytes:msg ~mime
           in
           Ok
             (Tool_output.encode_for_oas
                (Tool_output.Stored reference))
         with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          let message = Printexc.to_string exn in
          Log.Misc.error "tool_bridge: blob externalization failed: %s" message;
          Error { message })

(** {1 Result Conversion} *)

let make_tool_error ?(recoverable = false) ?error_class message
  : Agent_sdk.Types.tool_result =
  Error { Agent_sdk.Types.message; recoverable; error_class }

let project_content ?base_path message =
  maybe_externalize ?base_path message
;;

let externalization_tool_error ~recoverable _error =
  make_tool_error
    ~recoverable
    ~error_class:
      (if recoverable
       then Agent_sdk.Types.Transient
       else Agent_sdk.Types.Unknown)
    "tool output artifact storage failed"
;;

let oas_error_class_of_tool_failure_class = function
  | Tool_result.Transient_error -> Agent_sdk.Types.Transient
  | Tool_result.Policy_rejection
  | Tool_result.Workflow_rejection ->
    Agent_sdk.Types.Deterministic
  | Tool_result.Runtime_failure -> Agent_sdk.Types.Unknown
;;

(** {1 Schema Conversion}

    OAS owns the JSON Schema to [tool_param] contract. Invalid, missing, or
    ambiguous property types fail at this boundary instead of being guessed
    as strings or reduced to the first union member. *)

let params_of_json_schema schema =
  Agent_sdk.Mcp.json_schema_to_params schema
;;

(** {1 OAS Tool.t Creation}

    Create OAS [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

let project_result
      ?base_path
      ?on_externalization_error
      ~externalization_error_recoverable
      message
      on_content
  : Agent_sdk.Types.tool_result
  =
  match project_content ?base_path message with
  | Ok content -> on_content content
  | Error error ->
    Option.iter (fun observe -> observe error) on_externalization_error;
    externalization_tool_error
      ~recoverable:externalization_error_recoverable
      error
;;

let to_oas_typed_result
      ?base_path
      ?on_externalization_error
      ?(externalization_error_recoverable = true)
      (tr : Tool_result.result)
  : Agent_sdk.Types.tool_result
  =
  match tr with
  | Tool_result.Completed output ->
    project_result
      ?base_path
      ?on_externalization_error
      ~externalization_error_recoverable
      (Tool_result.message tr)
      (fun content ->
         Ok { Agent_sdk.Types.content; _meta = output.metadata })
  | Tool_result.Deferred output ->
    let disposition_field =
      "masc.tool_disposition", `String (Tool_result.string_of_disposition tr)
    in
    let metadata =
      match output.metadata with
      | None -> `Assoc [ disposition_field ]
      | Some metadata ->
        `Assoc [ disposition_field; "masc.payload", metadata ]
    in
    project_result
      ?base_path
      ?on_externalization_error
      ~externalization_error_recoverable
      (Tool_result.message tr)
      (fun content ->
         Ok { Agent_sdk.Types.content; _meta = Some metadata })
  | Tool_result.Failed { class_; message; _ } ->
    project_result
      ?base_path
      ?on_externalization_error
      ~externalization_error_recoverable
      message
      (fun message ->
       make_tool_error
         ~recoverable:(Tool_result.is_retryable class_)
         ~error_class:(oas_error_class_of_tool_failure_class class_)
         message)

(** Create an OAS [Tool.t] from a MASC tool schema and a typed handler.

    [handler] receives raw JSON args and returns a {!Tool_result.result}.
    The bridge converts the result to OAS [tool_result] automatically.

    {[
      let oas_tool = oas_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let oas_tool_of_masc
    ?descriptor
    ?base_path
    ?on_externalization_error
    ?externalization_error_recoverable
    ~name
    ~description
    ~input_schema
    handler : Agent_sdk.Tool.t =
  let parameters = params_of_json_schema input_schema in
  let oas_handler json_args =
    to_oas_typed_result
      ?base_path
      ?on_externalization_error
      ?externalization_error_recoverable
      (handler json_args)
  in
  Agent_sdk.Tool.create ?descriptor ~name ~description ~parameters oas_handler

let oas_tool_of_masc_with_execution_env
    ?descriptor
    ?base_path
    ?on_externalization_error
    ?externalization_error_recoverable
    ~name
    ~description
    ~input_schema
    handler
  : Agent_sdk.Tool.t
  =
  let parameters = params_of_json_schema input_schema in
  let oas_handler execution_env json_args =
    to_oas_typed_result
      ?base_path
      ?on_externalization_error
      ?externalization_error_recoverable
      (handler execution_env json_args)
  in
  Agent_sdk.Tool.create_with_execution_env
    ?descriptor
    ~name
    ~description
    ~parameters
    oas_handler

let () =
  Runtime_agent.set_oas_tool_of_masc_hook (fun ~name ~description ~input_schema handler ->
    oas_tool_of_masc ~name ~description ~input_schema handler)
