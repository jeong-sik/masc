(** Keeper_turn_up -- keeper start/reconfigure handler.

    Orchestrates the "masc_keeper_up" tool by delegating to:
    - {!Keeper_turn_up_args}: argument parsing and validation
    - {!Keeper_turn_up_create}: new keeper creation
    - {!Keeper_turn_up_update}: existing keeper reconfiguration *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

type tool_result = Keeper_types_profile.tool_result

let with_manifest_read_warnings warnings result =
  match warnings with
  | [] -> result
  | warnings ->
    let fields =
      match Tool_result.metadata result with
      | Some (`Assoc fields) -> fields
      | Some metadata -> [ "producer_metadata", metadata ]
      | None -> []
    in
    Tool_result.with_metadata
      (`Assoc
         (( "keeper_manifest_read_warnings"
          , `List
              (List.map
                 Keeper_turn_up_config_persistence.warning_to_yojson
                 warnings) )
          :: fields))
      result

let declarative_manifest_revision (p : Keeper_turn_up_args.parsed_args) =
  match p.declarative_manifest_snapshot with
  | Declarative_manifest_missing -> Keeper_turn_up_config_persistence.Missing
  | Declarative_manifest_present { sha256; _ } ->
    Keeper_turn_up_config_persistence.Sha256 sha256

(* The code is [Keeper_turn_up_update]'s exported constant, not a second copy
   of the spelling. It was a copy: the create branch here and the update
   branch there wrote the same literal twice, and a reader that matches one
   of them has no way to tell whether the other still agrees. *)
let config_revision_conflict ~expected ~observed =
  tool_result_error_data
    ~class_:Tool_result.Workflow_rejection
    (`Assoc
       [ "code", `String Keeper_turn_up_update.config_revision_conflict_code
       ; "expected", Keeper_turn_up_config_persistence.config_revision_to_yojson expected
       ; "observed", Keeper_turn_up_config_persistence.config_revision_to_yojson observed
       ])

let handle_keeper_up ctx args : tool_result =
  match Keeper_turn_up_args.parse ctx args with
  | Error result -> result
  | Ok p ->
    (match
       Keeper_turn_up_config_persistence.with_current_config_revision
         ~config:ctx.config
         ~keeper_name:p.name
         (fun revision -> revision, read_meta ctx.config p.name)
     with
     | Error e ->
       tool_result_error ~class_:Tool_result.Runtime_failure (Printf.sprintf "%s" e)
     | Ok { value = _, Error e; warnings } ->
       tool_result_error ~class_:Tool_result.Runtime_failure (Printf.sprintf "%s" e)
       |> with_manifest_read_warnings warnings
     | Ok { value = observed, Ok None; warnings } ->
       let expected_manifest = declarative_manifest_revision p in
       let expected = { observed with manifest = expected_manifest } in
       (if expected = observed
        then
          Keeper_turn_up_create.create_keeper
            ~expected_config_revision:expected
            ctx
            p
        else config_revision_conflict ~expected ~observed)
       |> with_manifest_read_warnings warnings
     | Ok { value = revision, Ok (Some old); warnings } ->
       Keeper_turn_up_update.update_keeper
         ~expected_config_revision:revision
         ctx
         p
         old
       |> with_manifest_read_warnings warnings)
