module Schema = Keeper_structured_output_schema

open Result.Syntax

let schema = "keeper.hitl-judge-original.v1"

let system_prompt () = Prompt_registry.render_prompt_template Prompt_names.judge_effect []

(* The contract sentence lives in the keeper.hitl_summary.output_contract
   template; this function only supplies the canonical schema as data. A
   template that does not render is logged and falls back to the bare schema
   JSON, never to instruction prose written here. *)
let canonical_output_contract () =
  let schema_json = Yojson.Safe.to_string Schema.hitl_context_summary_schema in
  match
    Prompt_registry.render_prompt_template
      Prompt_names.judge_effect_output_contract
      [ "schema_json", schema_json ]
  with
  | Ok text -> String.trim text
  | Error detail ->
    Log.Keeper.error
      "hitl summary output-contract prompt %s did not render, falling back to the bare \
       schema: %s"
      Prompt_names.judge_effect_output_contract
      detail;
    schema_json
;;

(* Exact-output requests go straight to a provider: no history, no media. *)
let message role text = Llm_provider.Types.text_message role text

let messages_of ~system_prompt ~output_contract ~context_bundle =
  [ message Llm_provider.Types.System system_prompt
  ; message Llm_provider.Types.User output_contract
  ; message Llm_provider.Types.User (Yojson.Safe.to_string context_bundle)
  ]
;;

type t =
  { approval_id : string
  ; input_hash : string
  ; sequence : int
  ; system_prompt : string
  ; output_contract : string
  ; context_bundle : Yojson.Safe.t
  }

let prepare ~(entry : Keeper_approval_queue_rules_types.pending_approval) =
  let* context_bundle =
    Hitl_summary_request.capture_context_bundle ~entry
    |> Lane_addon_action.canonical
  in
  let* system_prompt =
    system_prompt ()
    |> Result.map_error (fun detail -> "HITL Gate judgment prompt unavailable: " ^ detail)
  in
  Ok
    { approval_id = entry.id
    ; input_hash = entry.input_hash
    ; sequence = entry.sequence
    ; system_prompt
    ; output_contract = canonical_output_contract ()
    ; context_bundle
    }
;;

let approval_id t = t.approval_id
let input_hash t = t.input_hash
let sequence t = t.sequence
let system_prompt_text t = t.system_prompt
let output_contract t = t.output_contract
let context_bundle t = t.context_bundle

let messages t =
  messages_of
    ~system_prompt:t.system_prompt
    ~output_contract:t.output_contract
    ~context_bundle:t.context_bundle
;;

let field_names =
  [ "approval_id"
  ; "context_bundle"
  ; "input_hash"
  ; "output_contract"
  ; "schema"
  ; "sequence"
  ; "system_prompt"
  ]
;;

let to_json t =
  `Assoc
    [ "schema", `String schema
    ; "approval_id", `String t.approval_id
    ; "input_hash", `String t.input_hash
    ; "sequence", `Int t.sequence
    ; "system_prompt", `String t.system_prompt
    ; "output_contract", `String t.output_contract
    ; "context_bundle", t.context_bundle
    ]
;;

let of_json json =
  match json with
  | `Assoc fields ->
    let names = List.sort String.compare (List.map fst fields) in
    if names <> field_names
    then Error "HITL judge original has an unexpected field set"
    else (
      let text key =
        match List.assoc key fields with
        | `String value when String.trim value <> "" -> Ok value
        | _ -> Error (Printf.sprintf "HITL judge original %s must be non-blank text" key)
      in
      let* version = text "schema" in
      let* () =
        if String.equal version schema
        then Ok ()
        else Error "HITL judge original has an unknown schema"
      in
      let* approval_id = text "approval_id" in
      let* input_hash = text "input_hash" in
      let* system_prompt = text "system_prompt" in
      let* output_contract = text "output_contract" in
      let* sequence =
        match List.assoc "sequence" fields with
        | `Int value when value >= 0 -> Ok value
        | _ -> Error "HITL judge original sequence must be a non-negative integer"
      in
      let* context_bundle =
        Lane_addon_action.canonical (List.assoc "context_bundle" fields)
      in
      Ok
        { approval_id
        ; input_hash
        ; sequence
        ; system_prompt
        ; output_contract
        ; context_bundle
        })
  | _ -> Error "HITL judge original must be an object"
;;

let digest t =
  let* canonical = Lane_addon_action.canonical (to_json t) in
  Ok (Lane_addon_store.digest (Yojson.Safe.to_string canonical))
;;
