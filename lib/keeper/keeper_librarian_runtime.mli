(** Runtime adapter for Memory OS librarian extraction.

    [Keeper_librarian] owns pure prompt variables and JSON parsing. This module
    owns the side-effect boundary: render external prompts, call a provider, and
    append accepted episodes to [Keeper_memory_os_io]. *)

type complete_fn =
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Llm_provider.Provider_config.t ->
  messages:Agent_sdk.Types.message list ->
  unit ->
  (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result

val enabled : unit -> bool
(** Opt-in gate controlled by [MASC_KEEPER_MEMORY_OS_LIBRARIAN]. *)

val max_messages : unit -> int
(** Maximum recent checkpoint messages sent to the librarian prompt. *)

val default_timeout_sec : unit -> float
(** Provider timeout for post-turn extraction. Defaults to governance inference
    timeout and can be overridden with
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_TIMEOUT_SEC]. *)

val runtime_id_for_librarian : runtime_id:string -> string
(** Runtime id after applying the optional
    [MASC_KEEPER_MEMORY_OS_LIBRARIAN_RUNTIME_ID] override. *)

val select_recent_messages
  :  max_messages:int
  -> Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list

val messages_for_librarian
  :  Keeper_librarian.input
  -> (Agent_sdk.Types.message list, string) result

val provider_for_librarian
  :  Llm_provider.Provider_config.t
  -> Llm_provider.Provider_config.t

val librarian_max_parse_retries : int
(** Additional provider attempts after an initial unparseable response before
    [extract_with_provider] gives up (the initial attempt is not counted). *)

val parse_retry_nudge : string
(** Corrective instruction appended to the message list on each parse-retry. *)

type attempt_outcome =
  | Parsed of Keeper_memory_os_types.episode
  | Unparseable of string
  | Transport_failed of string

val run_with_parse_retries
  :  max_retries:int
  -> attempt:(Agent_sdk.Types.message list -> attempt_outcome)
  -> Agent_sdk.Types.message list
  -> (Keeper_memory_os_types.episode, string) result
(** Drive [attempt] over a growing message list. Returns immediately on [Parsed]
    (Ok) and [Transport_failed] (Error); on [Unparseable], appends
    {!parse_retry_nudge} and retries up to [max_retries] times before returning
    the last error. Pure given a pure [attempt] — the provider side effect lives
    in the [attempt] supplied by {!extract_with_provider}. *)

val extract_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> provider_cfg:Llm_provider.Provider_config.t
  -> max_concurrent:int option
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, string) result

val extract_and_append_with_provider
  :  ?complete:complete_fn
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?timeout_sec:float
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> keeper_id:string
  -> provider_cfg:Llm_provider.Provider_config.t
  -> max_concurrent:int option
  -> Keeper_librarian.input
  -> (Keeper_memory_os_types.episode, string) result

val run_best_effort
  :  ?complete:complete_fn
  -> ?timeout_sec:float
  -> runtime_id:string
  -> keeper_id:string
  -> Keeper_librarian.input
  -> unit
(** Run the opt-in post-turn librarian path.

    Non-cancel failures are logged and counted, never raised. *)
