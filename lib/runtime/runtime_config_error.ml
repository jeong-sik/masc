type drop_reason =
  | Binding_disabled
  | Provider_disabled of string (* provider id *)
  | Provider_not_declared of string (* provider id the binding names *)
  | Model_not_declared of string (* model id the binding names *)
  | Execution_unbuildable of string (* adapter's own reason *)

let string_of_drop_reason = function
  | Binding_disabled -> "binding is disabled by runtime.toml"
  | Provider_disabled id -> Printf.sprintf "provider %S is disabled by runtime.toml" id
  | Provider_not_declared id -> Printf.sprintf "provider not found: %s" id
  | Model_not_declared id -> Printf.sprintf "model not found: %s" id
  | Execution_unbuildable reason -> reason
;;
(* A list entry renders as "field entry \"id\"" and a scalar as "field = \"id\"".
   Keeping both is not cosmetic: [runtime].media_failover = "x" would tell the
   operator a list field equals one id. The variance is in rendering the site,
   never in deciding it. *)
type reference_shape =
  | Scalar
  | List_entry
(* Why an id named in runtime.toml did not become a runtime. [reason] carries
   the binding's own drop reason when something was declared under that id;
   [None] means nothing declared it, and [runtime_count] is what the message
   counts against. *)
type resolution_failure =
  { unresolved_id : string
  ; declared_drop : drop_reason option
  ; runtime_count : int
  }
(* One exact-output lane slot whose HTTP provider declares no
   [exact-body-timeout-s] (rule 3 of RFC-runtime-two-layers, #38779). *)
type exact_slot_body_deadline_gap =
  { lane_id : string
  ; slot_id : string
  ; provider_id : string
  }

(* What rule 3 left out of a loaded file: every gap, and the exact lanes
   those gaps emptied -- a lane whose every slot is a gap and that declares
   no cli_slots. Such a lane is unavailable on its own; the other lanes
   still publish. *)
type exact_slot_degradation =
  { gaps : exact_slot_body_deadline_gap list
  ; emptied_lane_ids : string list
  }

(* One declared [cli_slots] entry that resolves to a configured runtime the
   CLI tail cannot call: a provider-dispatched (HTTP / [Agent_core]) one, or
   an official client with no output-schema channel.
   [Keeper_lane_cli_oneshot.run] (the sole consumer of every lane's
   [cli_slots]) requires an official client and hands it an output schema on
   every call, so this is a load-time gap of the same shape as
   [exact_slot_body_deadline_gap] but a different rule: that one is about a
   missing timeout key, this one is about the runtime kind. See
   [exact_lane_cli_slot_gaps]. *)
type exact_lane_cli_slot_unservable_reason =
  | Not_an_official_client
  | Client_without_output_schema

type exact_lane_cli_slot_unservable =
  { lane_id : string
  ; slot_id : string
  ; provider_id : string
  ; reason : exact_lane_cli_slot_unservable_reason
  }

(* The ways loading runtime.toml fails, closed so a consumer decides per case
   instead of matching rendered text — the contract [drop_reason] already keeps
   one level down. [Toml_unparsable] is the single case whose text comes from
   the parser and can quote what the operator wrote; every other case names ids
   and config keys this repository authored. *)
type load_failure =
  | Toml_unparsable of Runtime_toml.parse_error list
  | Undeclared_bindings of (string * drop_reason) list
  | Default_runtime_absent
  | Default_runtime_unresolved of resolution_failure
  | Reference_unresolved of
      { site : string
      ; shape : reference_shape
      ; resolution : resolution_failure
      }
  | Lane_candidate_unresolved of
      { lane_id : string
      ; resolution : resolution_failure
      }
  | Max_context_absent of
      { runtime_id : string
      ; execution_model : string
      ; declared_model : string
      }
  | Exact_slot_body_deadlines_absent of exact_slot_body_deadline_gap list
  | Context_marks_exceed_max_context of
      { runtime_id : string
      ; high_water_tokens : int
      ; max_context : int
      }
  | Muse_window_below_host_overhead of
      { runtime_id : string
      ; max_context : int
      }
  | Exact_lane_cli_slot_unservable of exact_lane_cli_slot_unservable
(* A dangling reference is an operator typo, and unlike every other drop reason
   it is not survivable by ignoring the binding: the runtime the operator
   declared simply does not exist, and nothing downstream will say so unless the
   id happens to be referenced by an assignment, route, or lane. Reporting it
   here — at load, over the whole binding list — is what makes the absence
   visible without a reference to hang the message on (masc#28403). The other
   three reasons stay non-fatal: they keep the RFC-0206 §2.1 contract that a
   binding MASC cannot run is excluded rather than fatal. *)
let dangling_reference_reason = function
  | Provider_not_declared id ->
    Some (Printf.sprintf "names provider %S, which has no [providers.%s] row" id id)
  | Model_not_declared id ->
    Some (Printf.sprintf "names model %S, which has no [models.%s] row" id id)
  | Binding_disabled | Provider_disabled _ | Execution_unbuildable _ -> None
;;

let resolution_of ~(dropped_bindings : (string * drop_reason) list)
    ~(runtime_count : int) (id : string) : resolution_failure =
  { unresolved_id = id; declared_drop = List.assoc_opt id dropped_bindings; runtime_count }
;;

(* Rendering lives here now, and only here. Every message below is the one the
   failing site used to build inline, kept byte for byte: it is the operator's
   whole account of a refused configuration, and a reworded one would read as a
   different failure. *)
let resolution_suffix (resolution : resolution_failure) : string =
  match resolution.declared_drop with
  | Some reason ->
    Printf.sprintf
      ": binding is defined but could not be materialized as a runtime — %s"
      (string_of_drop_reason reason)
  | None -> Printf.sprintf " not found among %d runtimes" resolution.runtime_count
;;

(* One line per slot: the lane table, the slot, the provider and the key to
   add where it goes. The save refusal lists these, and so do the boot WARN
   and the startup degradation report. *)
let exact_slot_body_deadline_gap_to_string (gap : exact_slot_body_deadline_gap) =
  Printf.sprintf
    "[runtime.exact_output_lanes.%s] slot %S runs on provider %S; add %s to \
     [providers.%s]"
    gap.lane_id
    gap.slot_id
    gap.provider_id
    Runtime_schema.exact_body_timeout_s_key
    gap.provider_id
;;

let exact_slot_body_deadline_gap_to_yojson (gap : exact_slot_body_deadline_gap) =
  `Assoc
    [ "lane_id", `String gap.lane_id
    ; "slot_id", `String gap.slot_id
    ; "provider_id", `String gap.provider_id
    ; "missing_key", `String Runtime_schema.exact_body_timeout_s_key
    ; "message", `String (exact_slot_body_deadline_gap_to_string gap)
    ]
;;

let to_diagnostic_text ~(config_path : string) : load_failure -> string = function
  | Toml_unparsable errors ->
    let detail =
      errors
      |> List.map (fun (e : Runtime_toml.parse_error) ->
        Printf.sprintf "  - %s: %s" e.path e.message)
      |> String.concat "\n"
    in
    Printf.sprintf
      "runtime config parse failed (%s): %d error(s):\n%s"
      config_path
      (List.length errors)
      detail
  | Undeclared_bindings dropped ->
    let dangling =
      List.filter_map
        (fun (id, reason) ->
          Option.map
            (fun why -> Printf.sprintf "  %s %s" id why)
            (dangling_reference_reason reason))
        dropped
    in
    Printf.sprintf
      "%s: %d binding(s) reference a provider or model that is not declared, \
       so the runtime they define does not exist:\n%s"
      config_path
      (List.length dangling)
      (String.concat "\n" dangling)
  | Default_runtime_absent ->
    Printf.sprintf
      "%s: [runtime].default is required (no default runtime configured; \
       silent fallback removed)"
      config_path
  | Default_runtime_unresolved resolution ->
    (* The entry names a route: a declared lane or a runtime. The shared
       suffix counts runtimes alone, so the lane half is said here rather than
       leaving the reader to think only a runtime was ever allowed. *)
    Printf.sprintf
      "%s: [runtime].default = %S%s, and no [runtime.lanes] table declares it"
      config_path
      resolution.unresolved_id
      (resolution_suffix resolution)
  | Reference_unresolved { site; shape; resolution } ->
    let named =
      match shape with
      | Scalar -> Printf.sprintf "%s = %S" site resolution.unresolved_id
      | List_entry -> Printf.sprintf "%s entry %S" site resolution.unresolved_id
    in
    Printf.sprintf "%s: %s%s" config_path named (resolution_suffix resolution)
  | Lane_candidate_unresolved { lane_id; resolution } ->
    Printf.sprintf
      "%s: [runtime.lanes.%s] candidate %S%s"
      config_path
      lane_id
      resolution.unresolved_id
      (resolution_suffix resolution)
  | Max_context_absent { runtime_id; execution_model; declared_model } ->
    Printf.sprintf
      "%s: runtime %S (model=%s) has no [models.%s].max-context override \
       and no AGENT_CORE capability catalog max-context; set the override or add \
       the model to the capability catalog (no silent default — \
       RFC-0206 §2.1)"
      config_path
      runtime_id
      execution_model
      declared_model
  | Context_marks_exceed_max_context { runtime_id; high_water_tokens; max_context } ->
    Printf.sprintf
      "%s: runtime %S declares context-high-water-tokens = %d above the model's \
       max-context %d; a request that large is refused before the mark is \
       reached, so lower the mark or raise max-context"
      config_path
      runtime_id
      high_water_tokens
      max_context
  | Muse_window_below_host_overhead { runtime_id; max_context } ->
    Printf.sprintf
      "%s: runtime %S has no start-prompt ceiling: %s, so the host compacts any \
       input. Raise max-context"
      config_path
      runtime_id
      (Runtime_muse_prompt_capacity.error_to_string
         (Runtime_muse_prompt_capacity.Window_below_host_overhead { max_context }))
  | Exact_slot_body_deadlines_absent gaps ->
    Printf.sprintf
      "%s: this change adds %d exact-output slot(s) on a provider that declares \
       no %s. %s ends when the response headers arrive and does not bound the \
       response body, so %s is the only deadline on the whole request:\n%s"
      config_path
      (List.length gaps)
      Runtime_schema.exact_body_timeout_s_key
      Runtime_schema.connect_timeout_s_key
      Runtime_schema.exact_body_timeout_s_key
      (gaps
       |> List.map (fun gap -> "  " ^ exact_slot_body_deadline_gap_to_string gap)
       |> String.concat "\n")
  | Exact_lane_cli_slot_unservable
      { lane_id; slot_id; provider_id; reason = Not_an_official_client } ->
    Printf.sprintf
      "%s: [runtime.exact_output_lanes.%s].cli_slots entry %S is provider %S, \
       dispatched over HTTP rather than an official-client CLI; cli_slots \
       dispatches through the official-client CLI alone \
       (Keeper_lane_cli_oneshot), so move this id to slots or replace it with \
       an official-client runtime (protocol = \"claude-code\" / \
       \"codex-app-server\" / \"antigravity-cli\")"
      config_path
      lane_id
      slot_id
      provider_id
  | Exact_lane_cli_slot_unservable
      { lane_id; slot_id; provider_id; reason = Client_without_output_schema } ->
    Printf.sprintf
      "%s: [runtime.exact_output_lanes.%s] entry %S is provider %S, \
       whose client has no output-schema channel; exact-output lanes require \
       the selected client to accept a JSON Schema, so \
       remove this id or replace it with protocol = \"claude-code\" / \
       \"codex-app-server\" / \"antigravity-cli\""
      config_path
      lane_id
      slot_id
      provider_id
;;

(* The same account, minus the one part this repository did not write. A parse
   error's text comes from the TOML parser and can quote the line it choked on,
   which on an operator surface may be a value rather than a key. Every other
   case names ids and config keys, so it reads identically to the diagnostic.
   Listed case by case on purpose: a new failure has to decide where it
   belongs instead of falling into a default. *)
let to_operator_text ~(config_path : string) (failure : load_failure) : string =
  match failure with
  | Toml_unparsable errors ->
    Printf.sprintf
      "%s: %d parse error(s) in the file itself. Run masc runtime-probe for the \
       parser's own report."
      config_path
      (List.length errors)
  | Undeclared_bindings _
  | Default_runtime_absent
  | Default_runtime_unresolved _
  | Reference_unresolved _
  | Lane_candidate_unresolved _
  | Max_context_absent _
  | Context_marks_exceed_max_context _
  | Muse_window_below_host_overhead _
  | Exact_slot_body_deadlines_absent _
  | Exact_lane_cli_slot_unservable _ -> to_diagnostic_text ~config_path failure
;;
