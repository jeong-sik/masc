type deferred_kind =
  | Generic_deferred
  | External_effect_deferred

let deferred_kind_to_string = function
  | Generic_deferred -> "generic_deferred"
  | External_effect_deferred -> "external_effect_deferred"
;;

type terminal_effect_receipt =
  | Surface_post_completed of Keeper_surface_post.post_target
  | Memory_write_completed of { revision : int }
  | Memory_retract_completed of { revision : int }

let memory_revision_wire_key = "memory_revision"

type t =
  { raw_output : string
  ; data : Yojson.Safe.t option
  ; metadata : Yojson.Safe.t option
  ; failure_effect_disposition : Tool_result.failure_effect_disposition
  ; disposition :
      (unit, unit, Tool_result.tool_failure_class) Tool_result.disposition
  ; deferred_kind : deferred_kind option
  ; terminal_effect_receipt : terminal_effect_receipt option
  ; file_change_evidence : Keeper_file_change_evidence.t option
  }

(* Every payload that leaves here can land in a keeper transcript, where the
   checkpoint encoder refuses an object that binds a key twice -- and it does
   so after the tool has already run, which is how one keeper lost 12
   consecutive turns to a schedule result on 2026-08-29 (#31701). The inbound
   argument boundary resolves the same ambiguity through the same rule, so a
   repeat is answered identically in both directions. *)
let resolve_repeated_keys data =
  fst (Llm_provider.Json_object_keys.deduplicate data)
;;

let success raw_output =
  { raw_output
  ; data = None
  ; metadata = None
  ; failure_effect_disposition = Tool_result.Effect_outcome_unknown
  ; disposition = Tool_result.Completed ()
  ; deferred_kind = None
  ; terminal_effect_receipt = None
  ; file_change_evidence = None
  }
;;

let success_data ?metadata data =
  let data = resolve_repeated_keys data in
  { raw_output = Yojson.Safe.to_string data
  ; data = Some data
  ; metadata
  ; failure_effect_disposition = Tool_result.Effect_outcome_unknown
  ; disposition = Tool_result.Completed ()
  ; deferred_kind = None
  ; terminal_effect_receipt = None
  ; file_change_evidence = None
  }
;;

let deferred_data ?metadata data =
  let data = resolve_repeated_keys data in
  { raw_output = Yojson.Safe.to_string data
  ; data = Some data
  ; metadata
  ; failure_effect_disposition = Tool_result.Effect_outcome_unknown
  ; disposition = Tool_result.Deferred ()
  ; deferred_kind = Some Generic_deferred
  ; terminal_effect_receipt = None
  ; file_change_evidence = None
  }
;;

let deferred_external_effect_data ?metadata data =
  let data = resolve_repeated_keys data in
  { raw_output = Yojson.Safe.to_string data
  ; data = Some data
  ; metadata
  ; failure_effect_disposition = Tool_result.Effect_outcome_unknown
  ; disposition = Tool_result.Deferred ()
  ; deferred_kind = Some External_effect_deferred
  ; terminal_effect_receipt = None
  ; file_change_evidence = None
  }
;;

let failure
      ?(class_ = Tool_result.Runtime_failure)
      ?(effect_disposition = Tool_result.Effect_outcome_unknown)
      raw_output
  =
  { raw_output
  ; data = None
  ; metadata = None
  ; failure_effect_disposition = effect_disposition
  ; disposition = Tool_result.Failed class_
  ; deferred_kind = None
  ; terminal_effect_receipt = None
  ; file_change_evidence = None
  }
;;

let failure_data
      ~class_
      ?(effect_disposition = Tool_result.Effect_outcome_unknown)
      ?metadata
      ~message
      data
  =
  let data = resolve_repeated_keys data in
  { raw_output = message
  ; data = Some data
  ; metadata
  ; failure_effect_disposition = effect_disposition
  ; disposition = Tool_result.Failed class_
  ; deferred_kind = None
  ; terminal_effect_receipt = None
  ; file_change_evidence = None
  }
;;

let with_gate_authorization authorization result =
  { result with
    metadata =
      Some
        (Keeper_gate.authorization_metadata
           ?producer_metadata:result.metadata
           authorization)
  }
;;

let with_surface_post_receipt target result =
  match result.disposition with
  | Tool_result.Completed () ->
    { result with
      terminal_effect_receipt = Some (Surface_post_completed target)
    }
  | Tool_result.Deferred () | Tool_result.Failed _ -> result
;;

let with_memory_write_receipt ~revision result =
  match result.disposition with
  | Tool_result.Completed () ->
    { result with terminal_effect_receipt = Some (Memory_write_completed { revision }) }
  | Tool_result.Deferred () | Tool_result.Failed _ -> result
;;

let with_memory_retract_receipt ~revision result =
  match result.disposition with
  | Tool_result.Completed () ->
    { result with terminal_effect_receipt = Some (Memory_retract_completed { revision }) }
  | Tool_result.Deferred () | Tool_result.Failed _ -> result
;;

let with_file_change_evidence evidence result =
  match result.disposition with
  | Tool_result.Completed () ->
    { result with file_change_evidence = Some evidence }
  | Tool_result.Deferred () | Tool_result.Failed _ -> result
;;

let of_tool_result
      ?(failure_effect_disposition = Tool_result.Effect_outcome_unknown)
      (result : Tool_result.result)
  =
  let raw_output = Tool_result.message result in
  let data = Some (Tool_result.data result) in
  match result with
  | Tool_result.Completed { metadata; _ } ->
    { raw_output
    ; data
    ; metadata
    ; failure_effect_disposition = Tool_result.Effect_outcome_unknown
    ; disposition = Tool_result.Completed ()
    ; deferred_kind = None
    ; terminal_effect_receipt = None
    ; file_change_evidence = None
    }
  | Tool_result.Deferred { metadata; _ } ->
    { raw_output
    ; data
    ; metadata
    ; failure_effect_disposition = Tool_result.Effect_outcome_unknown
    ; disposition = Tool_result.Deferred ()
    ; deferred_kind = Some Generic_deferred
    ; terminal_effect_receipt = None
    ; file_change_evidence = None
    }
  | Tool_result.Failed { class_; _ } ->
    { raw_output
    ; data
    ; metadata = Tool_result.metadata result
    ; failure_effect_disposition
    ; disposition = Tool_result.Failed class_
    ; deferred_kind = None
    ; terminal_effect_receipt = None
    ; file_change_evidence = None
    }
;;
