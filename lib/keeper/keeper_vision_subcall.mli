(** Phase 1 impure shell for [analyze_image] (RFC-keeper-vision-delegation §2.6).

    A bounded, mid-turn vision provider sub-call. Composes the pure cores
    {!Vision_analyze} (request validation + extraction classification) with a
    single {!Llm_provider.Complete.complete} round-trip, wrapped in a hard
    [Eio.Time.with_timeout_exn] so a slow vision runtime can never stall the
    keeper turn or the single Eio domain ("one keeper stalls all" is P0).

    Lives in [lib/keeper] (not [lib/multimodal]) so the multimodal cores stay
    free of the [llm_provider]/[agent_sdk] transport dependency; the librarian
    already calls [Complete.complete] from this layer. The [complete] seam
    mirrors [Keeper_librarian_runtime]'s test seam, so {!run} is unit-testable
    without a real provider. *)

type error =
  | Missing_artifact of string
      (** The artifact bytes could not be loaded ({!Vision_artifact_store.load}
          [Error]: non-canonical handle / absent file / corruption). *)
  | Subcall_failed of string
      (** The provider HTTP round-trip returned an error (rendered message). *)
  | Timed_out of float
      (** The sub-call exceeded the bound (seconds). The hard P0 guard. *)
  | Extraction of Multimodal.Vision_analyze.extraction_error
      (** The provider replied but {!Multimodal.Vision_analyze.classify} rejected it
          (empty / budget-truncated). Never a silent [Ok ""]. *)
  | No_vision_runtime
      (** No image-capable runtime is configured to delegate to. *)

val string_of_error : error -> string
(** Stable, keeper-facing tag, e.g. ["missing_artifact: <msg>"],
    ["timeout: vision sub-call exceeded <s>s"], ["truncated_extraction"]. Reuses
    {!Multimodal.Vision_analyze.string_of_error} for the [Extraction] arm so the
    empty/truncated vocabulary has one owner. *)

type complete_fn =
  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?body_timeout_s:float
  -> config:Llm_provider.Provider_config.t
  -> messages:Agent_sdk.Types.message list
  -> unit
  -> (Agent_sdk.Types.api_response, Llm_provider.Http_client.http_error) result
(** The provider-call seam. {!default_complete} is the real
    {!Llm_provider.Complete.complete}; tests inject a fake to exercise {!run}
    without a network. *)

val default_complete : complete_fn
(** [= Llm_provider.Complete.complete] (the same symbol the librarian calls). *)

val run
  :  ?complete:complete_fn
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> provider_config:Llm_provider.Provider_config.t
  -> timeout_sec:float
  -> Multimodal.Vision_analyze.request
  -> (string, error) result
(** Build a one-shot [User [Text query; Image (media_type, bytes)]] message,
    call [complete] under [Eio.Time.with_timeout_exn clock timeout_sec]
    (also forwarding [body_timeout_s = timeout_sec] for provider-side
    attribution), then extract text + stop-reason and run
    {!Multimodal.Vision_analyze.classify}.

    [clock] is REQUIRED (not optional): the hard timeout must fire on the
    turn's clock. Returns:
    - [Ok text] for a non-empty extraction (usable even if truncated);
    - [Error (Timed_out timeout_sec)] if the bound elapsed;
    - [Error (Subcall_failed _)] on a provider HTTP error;
    - [Error (Extraction _)] on an empty/truncated reply.
    Never returns [Ok ""]. [Eio.Cancel.Cancelled] (turn cancelled) propagates
    uncaught; only [Eio.Time.Timeout] becomes [Timed_out]. *)
