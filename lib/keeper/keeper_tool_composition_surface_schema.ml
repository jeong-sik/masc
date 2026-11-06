module Catalog = Keeper_tool_composition_catalog
module Journal = Keeper_tool_execution_journal
open Result.Syntax

type owner_metadata_refusal =
  | Owner_metadata_missing
  | Owner_metadata_mismatch

type continuation_refusal =
  | Current_leaf_denied of Keeper_composition_draft.continuation_refusal
  | Original_producer_absent of Skill_reference.t
  | Original_producer_changed of Skill_reference.t
  | Original_owner_metadata_refused of owner_metadata_refusal

let continuation_refusal_to_json = function
  | Current_leaf_denied refusal -> Keeper_composition_draft.continuation_refusal_to_json refusal
  | Original_producer_absent reference -> `Assoc
      ["kind",`String "original_producer_absent";"skill_reference",Skill_reference.to_yojson reference]
  | Original_producer_changed reference -> `Assoc
      ["kind",`String "original_producer_changed";"skill_reference",Skill_reference.to_yojson reference]
  | Original_owner_metadata_refused Owner_metadata_missing -> `Assoc
      ["kind",`String "owner_metadata_missing"]
  | Original_owner_metadata_refused Owner_metadata_mismatch -> `Assoc
      ["kind",`String "owner_metadata_mismatch"]

let validate_original_producer_activation ~config (source : Journal.source) =
  match source.producer with
  | Journal.Prepared | Named {origin=Nested _;_} -> Ok ()
  | Named {origin=Standalone;activation=None;_} -> Error "original named activation context is missing"
  | Named {origin=Standalone;activation=Some bound;tool_name;skill_reference} ->
    let* original = Keeper_skill_activation_recorder.find_bound_composition ~config bound
        ~tool_use_id:source.parent_tool_use_id ~source_turn:source.source_turn ~tool_name skill_reference
        |> Result.map_error Keeper_skill_activation_recorder.error_to_string in
    (match original with Some _ -> Ok () | None -> Error "original named activation is missing")

let composition_run_summary_tool_name = "keeper_composition_run_summary"

let request_id_of_validated_input = function
  | `Assoc fields ->
    (match List.assoc_opt "request_id" fields with
     | Some (`String request_id) -> Some request_id
     | Some _ | None -> None)
  | _ -> None
;;

let entry_description (entry : Catalog.entry) =
  Option.value
    ~default:
      (match entry.execution with
       | Catalog.Inline ->
         "Execute the validated Keeper composition " ^ entry.name ^ "."
       | Catalog.Async ->
         "Start the validated read-only Keeper composition "
         ^ entry.name
         ^ " and return its durable request id.")
    entry.description
;;


;;

let schema_tool ~name ~description ~input_schema =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~name
    ~description
    ~input_schema
    (fun _ _ -> invalid_arg "schema-only Keeper tool cannot execute")
;;

let skill_tool_schema : Masc_domain.tool_schema = Tool_schemas_skill.schema

type instruction_skill =
  { reference : Skill_reference.t
  ; description : string
  ; body : string
  ; resource_location : resource_location option
  }

and resource_location =
  { source_root : string
  ; directory : string
  ; resource_read_max_bytes : Skill_source_config.resource_read_max_bytes
  }

type composition_skill =
  { reference : Skill_reference.t
  ; entry : Catalog.entry
  }

(* Each line carries what a call needs and nothing else: the identity, copyable
   straight into the tool's [identity] argument. It used to carry the whole
   reference, whose 64-hex content_revision is the larger half of every line and
   is no longer asked for — the turn's frozen list decides that (RFC-0411 §4.2).
   The revision comes back only on a refusal, where it is the one thing that can
   still separate two Skills sharing an identity. *)
let instruction_skill_description (instruction_skills : instruction_skill list) =
  let listed =
    instruction_skills
    |> List.map (fun (skill : instruction_skill) ->
         Printf.sprintf
           "%s: %s"
           (Skill_reference.identity_to_yojson skill.reference.identity
            |> Yojson.Safe.to_string)
           skill.description)
    |> String.concat "\n"
  in
  skill_tool_schema.description ^ "\n\nAvailable:\n" ^ listed
;;

(* Every refusal that turns on the reference answers with the references the
   keeper actually carries. A caller without the revision at hand — the log
   shows empty strings and copied placeholders — has to be handed the exact
   value here, because nothing else on its surface can say it (task-828). *)
let carried_references_text (instruction_skills : instruction_skill list) =
  match instruction_skills with
  | [] -> "(none)"
  | skills ->
    String.concat
      ", "
      (List.map
         (fun (skill : instruction_skill) ->
            Skill_reference.to_yojson skill.reference |> Yojson.Safe.to_string)
         skills)
;;

type 'evidence schema_tool_origin =
  | Declared_composition of 'evidence
  | Async_status
  | Async_cancel
  | Transient_prepare
  | Transient_run

let composition_schema_tool (entry : Catalog.entry) =
  schema_tool
    ~name:(Catalog.tool_name entry)
    ~description:(entry_description entry)
    ~input_schema:(Catalog.input_schema_of_params entry.params)
;;

(* Row selection and order are shared by schemas and the names-only view.
   Retain entries beside caller evidence until the requested projection. *)
let schema_tool_origins ~include_drafts ~skill_compositions =
  let compositions = List.map (fun row -> Declared_composition row) skill_compositions in
  let controls =
    if include_drafts || Catalog.requires_async_controls (List.map fst skill_compositions)
    then [Async_status; Async_cancel]
    else [] in
  let drafts = if include_drafts then [Transient_prepare; Transient_run] else [] in
  compositions @ controls @ drafts
;;

let schema_tool_name_rows ?(include_drafts = true) ?(skill_compositions = []) () =
  schema_tool_origins ~include_drafts ~skill_compositions
  |> List.map (function
       | Declared_composition (entry, evidence) ->
           Declared_composition evidence, Catalog.tool_name entry
       | Async_status -> Async_status, Catalog.status_tool_name
       | Async_cancel -> Async_cancel, Catalog.cancel_tool_name
       | Transient_prepare -> Transient_prepare, Catalog.prepare_tool_name
       | Transient_run -> Transient_run, Catalog.run_tool_name)
;;

let schema_tool_rows ?(include_drafts = true) ?(skill_compositions = []) () =
  schema_tool_origins ~include_drafts ~skill_compositions
  |> List.map (function
       | Declared_composition (entry, evidence) ->
           Declared_composition evidence, composition_schema_tool entry
       | Async_status ->
           Async_status, schema_tool
             ~name:Catalog.status_tool_name
             ~description:Tool_schemas_composition_control.status_schema.description
             ~input_schema:Tool_schemas_composition_control.status_schema.input_schema
       | Async_cancel ->
           Async_cancel, schema_tool
             ~name:Catalog.cancel_tool_name
             ~description:Tool_schemas_composition_control.cancel_schema.description
             ~input_schema:Tool_schemas_composition_control.cancel_schema.input_schema
       | Transient_prepare ->
           Transient_prepare, schema_tool
             ~name:Catalog.prepare_tool_name
             ~description:Keeper_composition_draft.prepare_schema.description
             ~input_schema:Keeper_composition_draft.prepare_schema.input_schema
       | Transient_run ->
           Transient_run, schema_tool
             ~name:Catalog.run_tool_name
             ~description:Keeper_composition_draft.run_schema.description
             ~input_schema:Keeper_composition_draft.run_schema.input_schema)
;;
