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

type scoped_call =
  { scopes : Tool_contract.Resource_scope.t list
  ; handler : execution_env_tool_handler
  }

let scoped_call ~scope ?(additional_scopes = []) handler =
  { scopes = scope :: additional_scopes; handler }
;;

type ordinary_admission =
  | Static of Tool_contract.execution_mode
  | Concurrent_when of (Yojson.Safe.t -> bool)
  | Resource_scoped of
      (sw:Eio.Switch.t -> Yojson.Safe.t -> (scoped_call option, Types.tool_error) result)

type call_effect = Read_only | Effect_possible

type descriptor =
  | Ordinary_descriptor of
      { admission : ordinary_admission
      ; call_effect : Yojson.Safe.t -> call_effect
      ; prepared_for : execution_env_tool_handler option
      }
  | Terminal_descriptor of Tool_contract.failure_effect_disposition

let ordinary_descriptor ?(call_effect = fun _ -> Effect_possible) execution_mode =
  Ordinary_descriptor { admission = Static execution_mode; call_effect; prepared_for = None }

(* One predicate, one fact: an input it proves read-only is both admitted
   concurrently and certified read-only for retry. *)
let ordinary_descriptor_concurrent_when proves_read_only =
  Ordinary_descriptor
    { admission = Concurrent_when proves_read_only
    ; prepared_for = None
    ; call_effect =
        (fun input -> if proves_read_only input then Read_only else Effect_possible)
    }
;;

let ordinary_descriptor_scoped ~call_effect ~prepare =
  Ordinary_descriptor
    { admission = Resource_scoped prepare; call_effect
    ; prepared_for = None }
;;

let terminal_descriptor failure_effect = Terminal_descriptor failure_effect

let descriptor_execution_mode descriptor ~input =
  match descriptor with
  | Ordinary_descriptor { admission = Static execution_mode; _ } -> execution_mode
  | Ordinary_descriptor { admission = Concurrent_when proves_read_only; _ } ->
    if proves_read_only input then Tool_contract.Concurrent else Tool_contract.Serial
  | Ordinary_descriptor { admission = Resource_scoped _; _ } -> Tool_contract.Serial
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

type prepared_call =
  { input : Yojson.Safe.t
  ; handler : execution_env_tool_handler
  ; scopes : Tool_contract.Resource_scope.t list option
  }

let prepare_call ~sw (tool : t) ~input =
  match tool.descriptor with
  | Some (Ordinary_descriptor { admission = Resource_scoped prepare; prepared_for; _ }) ->
    (match prepared_for with
     | Some expected when expected == tool.handler ->
       (match prepare ~sw input with
        | Ok (Some scoped) -> { input; handler = scoped.handler; scopes = Some scoped.scopes }
        | Ok None -> { input; handler = tool.handler; scopes = None }
        | Error error -> { input; handler = (fun _ _ -> Error error); scopes = None })
     | Some _ | None -> { input; handler = tool.handler; scopes = None })
  | Some (Ordinary_descriptor { admission = (Static _ | Concurrent_when _); _ })
  | Some (Terminal_descriptor _) | None ->
    { input; handler = tool.handler; scopes = None }
;;

let prepared_call_scopes (call : prepared_call) = call.scopes

let has_scoped_admission (tool : t) =
  match tool.descriptor with
  | Some (Ordinary_descriptor { admission = Resource_scoped _; prepared_for; _ }) ->
    (match prepared_for with Some expected -> expected == tool.handler | None -> false)
  | Some (Ordinary_descriptor { admission = (Static _ | Concurrent_when _); _ })
  | Some (Terminal_descriptor _) | None -> false
;;

let map_handler wrap (tool : t) =
  let handler = wrap tool.handler in
  let descriptor = match tool.descriptor with
    | Some (Ordinary_descriptor ({ admission = Resource_scoped prepare; _ } as ordinary))
      when has_scoped_admission tool ->
      let prepare ~sw input =
        Result.map
          (Option.map (fun (scoped : scoped_call) -> { scoped with handler = wrap scoped.handler }))
          (prepare ~sw input)
      in
      Some (Ordinary_descriptor
        { ordinary with admission = Resource_scoped prepare; prepared_for = Some handler })
    | Some (Ordinary_descriptor { admission = (Static _ | Concurrent_when _ | Resource_scoped _); _ })
    | Some (Terminal_descriptor _) | None -> tool.descriptor
  in
  { tool with handler; descriptor }
;;

let execute_prepared ?context ?invocation (call : prepared_call) =
  call.handler (Execution_env.create ?context ?invocation ()) call.input
;;

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
  let descriptor = match descriptor with
    | Some (Ordinary_descriptor ({ admission = Resource_scoped _; _ } as ordinary)) ->
      Some (Ordinary_descriptor { ordinary with prepared_for = Some handler })
    | Some (Ordinary_descriptor { admission = (Static _ | Concurrent_when _); _ })
    | Some (Terminal_descriptor _) | None -> descriptor in
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
let execute ?context ?invocation (tool : t) input =
  tool.handler (Execution_env.create ?context ?invocation ()) input
;;

let descriptor tool = tool.descriptor

let call_effect tool input =
  match tool.descriptor with
  | Some (Ordinary_descriptor { admission = Resource_scoped _; call_effect; _ }) ->
    if has_scoped_admission tool then call_effect input else Effect_possible
  | Some (Ordinary_descriptor { admission = (Static _ | Concurrent_when _); call_effect; _ }) ->
    call_effect input
  | Some (Terminal_descriptor _) | None -> Effect_possible
;;

let execution_mode tool ~input =
  Option.fold
    ~none:Tool_contract.Serial
    ~some:(descriptor_execution_mode ~input)
    tool.descriptor
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
        , match descriptor with
          | Ordinary_descriptor { admission = Concurrent_when _; _ } -> `String "concurrent_when_read_only"
          | Ordinary_descriptor { admission = Static execution_mode; _ } ->
            Tool_contract.execution_mode_to_yojson execution_mode
          | Ordinary_descriptor { admission = Resource_scoped _; _ } ->
            `String "resource_scoped"
          | Terminal_descriptor _ ->
            Tool_contract.execution_mode_to_yojson Tool_contract.Serial )
      ; ( "completion"
        , Tool_contract.completion_to_yojson (descriptor_completion descriptor) )
      ]
;;

(* A schema is immutable — the record is [private] with only two constructors
   and every field holds immutable data — so physical schema identity
   determines the wire form. Memoizing on that identity turns the per-step
   re-serialization of an unchanged tool surface into a table lookup. The
   ephemeron holds keys weakly, so a schema nobody references releases its
   cached wire form instead of outliving its tool. *)
module Wire_schema_key = struct
  type t = Types.tool_schema

  let equal = (==)
  let hash (schema : t) = Hashtbl.hash schema.name
end

module Wire_schema_cache = Ephemeron.K1.Make (Wire_schema_key)

type wire_schema_entry =
  | Json_only of Yojson.Safe.t
  | Json_with_byte_count of
      { json : Yojson.Safe.t
      ; byte_count : int
      }

let wire_schema_cache : wire_schema_entry Wire_schema_cache.t = Wire_schema_cache.create 0
let wire_schema_cache_mutex = Stdlib.Mutex.create ()

(** Schema to JSON *)
let wire_json_of_schema_uncached (schema : Types.tool_schema) =
  `Assoc
    ([ "name", `String schema.name
     ; "description", `String schema.description
       (* The authoritative schema goes to the provider verbatim. Deriving it
          back from [parameters] would drop minimum/maximum/default/enum and
          nested properties, which the model then never sees. *)
     ; ( "input_schema"
       , match schema.input_schema with
         | Some authoritative -> authoritative
         | None -> Types.params_to_input_schema schema.parameters )
     ]
     @
     match schema.strict with
     | Some strict -> [ "strict", `Bool strict ]
     | None -> [])
;;

(* Product lookup and publication have one implementation in every observation
   mode. Return the lookup outcome while holding the cache mutex; diagnostic
   bookkeeping consumes it only after that mutex has been released. *)
let wire_schema_entry_locked schema =
  match Wire_schema_cache.find_opt wire_schema_cache schema with
  | Some entry -> entry, Schema_observation.Existing_json
  | None ->
    let entry = Json_only (wire_json_of_schema_uncached schema) in
    Wire_schema_cache.add wire_schema_cache schema entry;
    entry, Schema_observation.Created_json
;;

let wire_json_of_schema schema =
  let entry, outcome =
    Schema_observation.measure ~site:Sdk_wire_json ~schema (fun () ->
      Stdlib.Mutex.protect wire_schema_cache_mutex (fun () ->
        wire_schema_entry_locked schema))
  in
  Schema_observation.cache ~schema (Json_lookup outcome);
  match entry with
  | Json_only json | Json_with_byte_count { json; _ } -> json
;;

(* What one tool costs the request that carries it. Exported so a caller
   measuring the surface cannot reach for [Types.tool_schema_to_yojson]
   instead: that one also emits [parameters], the derived validation view no
   provider receives, which put masc's Execute at 10,396 bytes against the
   7,239 it sends. *)
let wire_bytes_of_schema schema =
  let entry, json =
    Schema_observation.measure ~site:Sdk_byte_count_lookup ~schema (fun () ->
      Stdlib.Mutex.protect wire_schema_cache_mutex (fun () ->
        wire_schema_entry_locked schema))
  in
  let count = match entry with
    | Json_with_byte_count _ -> Schema_observation.Existing_byte_count
    | Json_only _ -> Schema_observation.Missing_byte_count in
  Schema_observation.cache ~schema (Byte_lookup {json; count});
  match entry with
  | Json_with_byte_count { byte_count; _ } -> byte_count
  | Json_only json ->
    (* Keep encoding out of the shared critical section. A concurrent reader
       may publish first; retain its entry and the original JSON identity.
       Only the integer survives, not the temporary compact string. *)
    let byte_count =
      String.length
        (Schema_observation.encode ~site:Sdk_byte_count_encode ~schema (fun () ->
           Yojson.Safe.to_string json)) in
    let byte_count, publication =
      Schema_observation.measure ~site:Sdk_byte_count_publication ~schema (fun () ->
        Stdlib.Mutex.protect wire_schema_cache_mutex (fun () ->
          let entry, _ = wire_schema_entry_locked schema in
          match entry with
          | Json_with_byte_count { byte_count; _ } ->
            byte_count, Schema_observation.Concurrent_byte_count_won
          | Json_only json ->
            Wire_schema_cache.replace
              wire_schema_cache schema (Json_with_byte_count { json; byte_count });
            byte_count, Schema_observation.Published_byte_count)) in
    Schema_observation.cache ~schema (Byte_publication publication);
    byte_count
;;

let schema_to_json tool = wire_json_of_schema tool.schema

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
  let descriptor =
    match tool.descriptor with
    | Some (Ordinary_descriptor ordinary) ->
      let call_effect input = ordinary.call_effect (inject_defaults input) in
      let admission, prepared_for = match ordinary.admission with
        | Static mode -> Static mode, ordinary.prepared_for
        | Concurrent_when proves_read_only ->
          Concurrent_when (fun input -> proves_read_only (inject_defaults input)), ordinary.prepared_for
        | Resource_scoped prepare when has_scoped_admission tool ->
          let prepare ~sw input =
            match prepare ~sw (inject_defaults input) with
            | Ok (Some scoped) ->
              Ok (Some { scoped with handler =
                (fun env input -> scoped.handler env (inject_defaults input)) })
            | Ok None -> Ok None
            | Error error -> Error error
          in
          Resource_scoped prepare, Some handler
        | Resource_scoped _ -> ordinary.admission, ordinary.prepared_for
      in
      Some (Ordinary_descriptor { admission; prepared_for; call_effect })
    | Some (Terminal_descriptor _) | None -> tool.descriptor
  in
  { tool with handler; descriptor }
;;
