type holder_departure =
  | Keeper_stopped
  | Credential_expired
  | No_credential
  | Participant_departed

type admission = {
  observed_holder : string option;
  release : holder_departure option;
  handoff_target : string option;
}
let snapshot_tool = "lane_controller_snapshot"
let release_tool = "lane_controller_release"
let nullable_name = function None -> `Null | Some name -> `String name
let admission_to_json admission =
  `Assoc ["observed_holder", nullable_name admission.observed_holder;
    "release", (match admission.release with
      | None -> `Null | Some Keeper_stopped -> `String "keeper_stopped"
      | Some Credential_expired -> `String "credential_expired"
      | Some No_credential -> `String "no_credential"
      | Some Participant_departed -> `String "participant_departed");
    "handoff_target", nullable_name admission.handoff_target]
open Result.Syntax
let name = function
  | `Null -> Ok None
  | `String name when name <> "" && String.equal name (String.trim name) -> Ok (Some name)
  | _ -> Error "invalid controller name"
let admission_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)
      = ["handoff_target"; "observed_holder"; "release"] ->
      let* observed_holder = name (List.assoc "observed_holder" fields) in
      let* handoff_target = name (List.assoc "handoff_target" fields) in
      let* release = match List.assoc "release" fields with
        | `Null -> Ok None
        | `String "keeper_stopped" -> Ok (Some Keeper_stopped)
        | `String "credential_expired" -> Ok (Some Credential_expired)
        | `String "no_credential" -> Ok (Some No_credential)
        | `String "participant_departed" -> Ok (Some Participant_departed)
        | _ -> Error "invalid controller departure" in
      if release <> None && observed_holder = None then
        Error "controller release requires an observed holder"
      else Ok { observed_holder; release; handoff_target }
  | _ -> Error "invalid or duplicate controller admission fields"
let admission_schema = `Assoc [
  "type", `String "object"; "additionalProperties", `Bool false;
  "required", `List (List.map (fun s -> `String s)
    ["observed_holder"; "release"; "handoff_target"]);
  "properties", `Assoc [
    "observed_holder", `Assoc ["type", `List [`String "string"; `String "null"]];
    "handoff_target", `Assoc ["type", `List [`String "string"; `String "null"]];
    "release", `Assoc ["enum", `List [`Null; `String "keeper_stopped";
      `String "credential_expired"; `String "no_credential";
      `String "participant_departed"]]]]

type dos_tool =
  | Dos_load
  | Dos_eject
  | Dos_pass
  | Dos_meta
  | Dos_inventory
  | Dos_screen
  | Dos_step
  | Dos_press
  | Dos_click
  | Dos_type
  | Dos_peek
  | Dos_save
  | Dos_restore
[@@deriving enumerate]

let dos_tool_name = function
  | Dos_load -> "masc_dos_load"
  | Dos_eject -> "masc_dos_eject"
  | Dos_pass -> "masc_dos_pass"
  | Dos_meta -> "masc_dos_meta"
  | Dos_inventory -> "masc_dos_inventory"
  | Dos_screen -> "masc_dos_screen"
  | Dos_step -> "masc_dos_step"
  | Dos_press -> "masc_dos_press"
  | Dos_click -> "masc_dos_click"
  | Dos_type -> "masc_dos_type"
  | Dos_peek -> "masc_dos_peek"
  | Dos_save -> "masc_dos_save"
  | Dos_restore -> "masc_dos_restore"

let dos_tool_of_name name =
  List.find_opt (fun tool -> String.equal (dos_tool_name tool) name) all_of_dos_tool

type controller_need =
  | Takes_controller
  | Hands_controller
  | No_controller

let controller_need = function
  | Dos_load | Dos_eject | Dos_step | Dos_press | Dos_click | Dos_type
  | Dos_restore -> Takes_controller
  | Dos_pass -> Hands_controller
  | Dos_meta | Dos_inventory | Dos_screen | Dos_peek | Dos_save -> No_controller

type call_effect =
  | Reads_only
  | Changes_state

let call_effect = function
  | Dos_meta | Dos_inventory | Dos_screen | Dos_peek -> Reads_only
  | Dos_load | Dos_eject | Dos_pass | Dos_step | Dos_press | Dos_click | Dos_type
  | Dos_save | Dos_restore -> Changes_state

(* The recipient of a hand-off. [to] left out (or null) frees the controller;
   that is the only way to free it. An empty or blank [to] is an error: a
   caller whose template left the name unset would otherwise hand the machine
   to whoever moves it next. [parse] is the caller's agent-id rule, so the
   host that admits the call, the worker that runs it and the in-process tool
   all read one grammar of arguments and differ only in what a valid name is. *)
let pass_target ~parse arguments =
  let named = match arguments with `Assoc fields -> List.assoc_opt "to" fields | _ -> None in
  match named with
  | None | Some `Null -> Ok None
  | Some (`String text) ->
    let trimmed = String.trim text in
    if trimmed = "" then
      Error "to is empty: name the Keeper who takes the controller, or leave to out to free it"
    else
      (match parse trimmed with
       | Ok name -> Ok (Some name)
       | Error _ ->
         Error
           (Printf.sprintf "to %S is not a Keeper name: give the name alone, without @ or spaces"
              text))
  | Some _ -> Error "to must be a Keeper name, or left out to free the controller"

type screen_error =
  | Screen_no_machine
  | Screen_capture_failed
  | Screen_encode_failed
[@@deriving enumerate]

let screen_error_meta_key = "io.github.jeong-sik/masc.machine.screenError"

let screen_error_code = function
  | Screen_no_machine -> "no_machine"
  | Screen_capture_failed -> "capture_failed"
  | Screen_encode_failed -> "encode_failed"

let screen_error_meta_field error = (screen_error_meta_key, `String (screen_error_code error))

let screen_error_of_meta = function
  | Some (`Assoc fields) ->
    (match List.assoc_opt screen_error_meta_key fields with
     | Some (`String code) ->
       List.find_opt (fun error -> String.equal (screen_error_code error) code) all_of_screen_error
     | Some _ | None -> None)
  | Some _ | None -> None
