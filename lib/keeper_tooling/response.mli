(** Keeper_tooling.Response - provider response acceptance and keeper reply text
    normalization. *)

(** Keep [text] when non-blank. A blank tool-only turn remains blank because
    its tool timeline is the user-facing progress surface; a blank turn with no
    tools is an error. Hidden reasoning is never user-facing fallback text. *)
val normalize_response_text
  :  text:string
  -> tool_names:string list
  -> unit
  -> (string, string) result

type accept_rejection_kind =
  | No_usable_progress
  | Predicate_rejected

type accept_rejection =
  { kind : accept_rejection_kind
  ; reason : string
  ; response_shape : Agent_core.Response_shape.content_shape option
  }

val accept_rejection_kind_to_string : accept_rejection_kind -> string

(** Format an accept rejection reason for a runtime attempt. When the built-in
    keeper progress contract would accept the response, the returned reason is
    tagged as a caller-specific predicate rejection instead of no-progress. *)
val accept_rejection_of_response :
  runtime_id:string -> Agent_core.Types.api_response -> accept_rejection

(** [true] when a provider response is both complete and carries AGENT_CORE-defined
    downstream-visible progress for runtime accept/reject. A typed [MaxTokens]
    terminal is incomplete even when it contains text, so it is rejected before
    keeper response finalization and can resume from its post-turn checkpoint.
    Content-shape classification delegates to
    [Agent_core.Response_shape.has_deliverable_content]; no provider/model name
    or free-form response text participates in the decision. *)
val response_has_text_or_tool_progress : Agent_core.Types.api_response -> bool
