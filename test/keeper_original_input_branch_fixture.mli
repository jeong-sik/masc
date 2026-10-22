open Masc

(** Shared setup for real original-input branch integration scenarios.
    The initial wait is produced by Core. Another Owner child publishes G;
    the stored response primitive installs C. Public acceptance remains guarded. *)
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
  net:Eio_context.eio_net -> clock:_ Eio.Time.clock ->
  workspace:Workspace.config -> session_dir:string -> invocation -> unit
(** Caller initializes the native execution runtime, workspace and keeper meta.
    Run actual Core InputRequired W, defer through its original Owner, publish
    independent G from a separate autonomous child, close that Owner, then
    commit exact operation-owned response C. Does not dispatch C or authorize
    public response acceptance. Failures raise an Alcotest assertion. *)

val expected_global_checkpoint_bytes : workspace:Workspace.config -> string
(** Read fixture bytes captured immediately after actual G publication. This is
    a comparison artifact, not an input/checkpoint ownership authority. *)
