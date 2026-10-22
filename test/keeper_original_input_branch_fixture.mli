open Masc

(** Shared setup for real original-input branch integration scenarios.
    The initial wait is produced by Core. Another Owner child publishes G;
    the public Owner response installs C through its exclusive maintenance child. *)
type invocation = {
  keeper_name : string;
  session_id : string;
  runtime_id : string;
  operation_id : Keeper_chat_operation.Operation_id.t;
  source : Yojson.Safe.t;
  input : Yojson.Safe.t;
  message : string;
  input_metadata : Agent_core.Types.metadata;
  system_prompt : string;
  provider_cfg : Llm_provider.Provider_config.t;
}

val prepare :
  ?response_before_global:bool ->
  net:Eio_context.eio_net -> clock:_ Eio.Time.clock ->
  workspace:Workspace.config -> session_dir:string -> invocation -> unit
(** Caller initializes the native execution runtime, workspace and keeper meta.
    Run actual Core InputRequired W, defer through its original Owner, publish
    independent G from a separate autonomous child, respond through the public
    Owner API, then close that Owner. C is queued until the next actual runner
    is ready. [response_before_global] accepts canonical C before G is published,
    exercising atomic detachment of its original response lineage. Does not
    dispatch C. Failures raise an Alcotest assertion. *)

val expected_global_checkpoint_bytes : workspace:Workspace.config -> string
(** Read fixture bytes captured immediately after actual G publication. This is
    a comparison artifact, not an input/checkpoint ownership authority. *)
