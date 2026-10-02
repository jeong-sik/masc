(** Admission of materialized runtimes and lane references before dispatch. *)

open Runtime_schema
open Runtime_config_error
open Runtime_instance
open Result.Syntax

let assignments_table = Runtime_toml_namespace.(path Runtime) "assignments"

(* Route ids resolve with lane precedence ([resolve_assignment] prefers a lane
   over a same-named runtime), so route validation must judge the same target
   the consumer will actually get: lane first, runtime second. *)
let find_declared_lane (lanes : Runtime_lane.t list) (id : string) =
  List.find_opt (fun lane -> String.equal (Runtime_lane.id lane) id) lanes
;;

(* Each [runtime] reference is validated under its field's admission contract:
   - [Runtime_only] requires a declared runtime id. media_failover is on it:
     its entries name runtimes that can read an image, and the order of that
     list is the whole walk. verifier_exact slots are on it: judgement admits
     each slot as a direct runtime and dispatches that id alone. No lane
     expands underneath either.
   - [Lane_then_runtime] admits a declared lane name or a runtime id. Keeper
     assignments and route ids are on it, so validation judges the same target
     [resolve_assignment] hands the consumer: lane first, runtime second.
   Unknown ids are rejected while loading the configuration. *)
type reference_domain =
  | Runtime_only
  | Lane_then_runtime

type runtime_reference =
  { site : string (* the config path as the operator wrote it *)
  ; shape : reference_shape
  ; id : string
  ; domain : reference_domain
  }

(* The list is carried out whole rather than counted here: the caller decides
   whether an operator sees it, and how much of it. *)
let validate_no_dangling_bindings
    ~(dropped_bindings : (string * drop_reason) list) : (unit, load_failure) result =
  match
    List.filter
      (fun (_, reason) -> Option.is_some (dangling_reference_reason reason))
      dropped_bindings
  with
  | [] -> Ok ()
  | dangling -> Error (Undeclared_bindings dangling)
;;

let validate_runtime_references
    ~(dropped_bindings : (string * drop_reason) list) (runtimes : t list)
    (lanes : Runtime_lane.t list) (references : runtime_reference list)
  : (unit, load_failure) result
  =
  let resolves_as_runtime id =
    List.exists (fun (r : t) -> String.equal r.id id) runtimes
  in
  let resolves (reference : runtime_reference) =
    match reference.domain with
    | Runtime_only -> resolves_as_runtime reference.id
    | Lane_then_runtime ->
      (* [validate_lanes] already guaranteed every candidate id of a declared
         lane resolves, so naming the lane is enough. *)
      Option.is_some (find_declared_lane lanes reference.id)
      || resolves_as_runtime reference.id
  in
  match List.find_opt (fun reference -> not (resolves reference)) references with
  | None -> Ok ()
  | Some { site; shape; id; domain = _ } ->
    Error
      (Reference_unresolved
         { site
         ; shape
         ; resolution =
             resolution_of ~dropped_bindings ~runtime_count:(List.length runtimes) id
         })
;;

(* Reference constructors keep each site string next to the field it names, so a
   renamed config key cannot drift away from its diagnostic. *)
let assignment_references (assignments : (string * string) list) =
  List.map
    (fun (keeper_name, runtime_id) ->
      { site = Printf.sprintf "[%s].%s" assignments_table keeper_name
      ; shape = Scalar
      ; id = runtime_id
      ; domain = Lane_then_runtime
      })
    assignments
;;

let media_failover_references (media_failover : string list) =
  List.map
    (fun id ->
      { site = "[runtime].media_failover"
      ; shape = List_entry
      ; id
      ; domain = Runtime_only
      })
    media_failover
;;

(* [runtime.lanes.<id>] candidate ids must resolve to configured runtimes.
   Empty candidate lists are rejected at parse time; here we reject unknown ids
   as operator typos (mirrors [runtime].default validation). *)
let validate_lanes
    ~(dropped_bindings : (string * drop_reason) list) (runtimes : t list)
    (lane_decls : Runtime_schema.lane_decl list)
  : (unit, load_failure) result
  =
  let runtime_exists id =
    List.exists (fun (r : t) -> String.equal r.id id) runtimes
  in
  let rec first_unknown = function
    | [] -> None
    | { Runtime_schema.id = lane_id; candidate_ids; _ } :: rest ->
      (match List.find_opt (fun id -> not (runtime_exists id)) candidate_ids with
       | Some id -> Some (lane_id, id)
       | None -> first_unknown rest)
  in
  match first_unknown lane_decls with
  | None -> Ok ()
  | Some (lane_id, id) ->
    Error
      (Lane_candidate_unresolved
         { lane_id
         ; resolution =
             resolution_of ~dropped_bindings ~runtime_count:(List.length runtimes) id
         })
;;

(* A lane is exactly the candidates it declares: a keeper reaches another
   runtime only when a lane names it. *)
let lanes_of_decls
    ~(dropped_bindings : (string * drop_reason) list)
    (runtimes : t list)
    (lane_decls : Runtime_schema.lane_decl list)
  : (Runtime_lane.t list, load_failure) result
  =
  let* () = validate_lanes ~dropped_bindings runtimes lane_decls in
  Ok
    (List.map
       (fun ({ Runtime_schema.id; candidate_ids } : Runtime_schema.lane_decl) ->
          Runtime_lane.make ~id candidate_ids)
       lane_decls)
;;

(* Every materialized runtime must resolve a positive context window from the
   runtime.toml override or the AGENT_CORE capability catalog. A binding that leaves
   both unset is a config error rejected here, not a runtime defaulted to a
   fallback window (RFC-0206 §2.1 no silent fallback). *)
let validate_runtime_max_context (runtimes : t list)
  : (unit, load_failure) result
  =
  match
    List.find_opt
      (fun (r : t) -> Option.is_none (resolve_max_context_of_runtime r))
      runtimes
  with
  | None -> Ok ()
  | Some r ->
    Error
      (Max_context_absent
         { runtime_id = r.id
         ; execution_model =
             (match Runtime_execution.model_id r.execution with
              | Some model_id -> model_id
              | None -> "<official-client-selected>")
         ; declared_model = r.model.id
         })
;;

(* Context marks are checked against the resolved binding/provider/model
   window, including any genuine provider catalog cap. *)
let validate_runtime_context_marks (runtimes : t list) : (unit, load_failure) result =
  match
    List.find_map
      (fun (r : t) ->
         match r.binding.Runtime_schema.context_marks, resolve_max_context_of_runtime r with
         | Some marks, Some (max_context, _)
           when marks.Runtime_schema.high_water_tokens > max_context ->
           Some
             (Context_marks_exceed_max_context
                { runtime_id = r.id
                ; high_water_tokens = marks.Runtime_schema.high_water_tokens
                ; max_context
                })
         | Some _, Some _ | Some _, None | None, (Some _ | None) -> None)
      runtimes
  with
  | None -> Ok ()
  | Some failure -> Error failure
;;

(* A Muse window too small for the host's own overhead leaves no start-prompt
   ceiling ([muse_prompt_capacity]), declared max-prompt-bytes or not, and is
   refused here rather than at its first turn. *)
let validate_muse_prompt_ceilings (runtimes : t list) : (unit, load_failure) result =
  match
    List.find_map
      (fun (r : t) ->
         match r.provider.api_format with
         | Muse_serve_runtime ->
           (match muse_prompt_capacity r with
            | Ok _ -> None
            | Error (Runtime_muse_prompt_capacity.Window_below_host_overhead { max_context }) ->
              Some (Muse_window_below_host_overhead { runtime_id = r.id; max_context })
            (* A runtime with no resolved window fails
               [validate_runtime_max_context] instead. *)
            | Error Runtime_muse_prompt_capacity.No_window_declared -> None)
         | Messages_api | Chat_completions_api | Ollama_api | Gemini_api
         | Vertex_gemini_api | Codex_app_server_runtime | Antigravity_cli_runtime
         | Claude_code_runtime -> None)
      runtimes
  with
  | None -> Ok ()
  | Some failure -> Error failure
;;
