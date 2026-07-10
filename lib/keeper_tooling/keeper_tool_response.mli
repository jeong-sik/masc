(** Keeper_tool_response - provider response acceptance and keeper reply text
    normalization. *)

(** Keep [text] when non-blank; otherwise synthesize a
    "No textual reply was produced. Tools invoked: ..." line if [tool_names]
    is non-empty, else error. The fallback reports only observed invocation;
    it does not claim that tools succeeded or the turn completed. Hidden
    reasoning is never user-facing fallback text. *)
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
  ; response_shape : Agent_sdk.Response_shape.content_shape option
  }

val accept_rejection_kind_to_string : accept_rejection_kind -> string

(** Operator-facing accept rejection reason for a response that failed the
    keeper progress contract. The reason reports response shape and counts only;
    it never includes hidden thinking text. Returns [None] when the built-in
    keeper progress contract would accept the response. *)
val response_accept_rejection : Agent_sdk.Types.api_response -> accept_rejection option

(** Format an accept rejection reason for a runtime attempt. When the built-in
    keeper progress contract would accept the response, the returned reason is
    tagged as a caller-specific predicate rejection instead of no-progress. *)
val accept_rejection_of_response :
  runtime_id:string -> Agent_sdk.Types.api_response -> accept_rejection

(** [true] when a provider response carries OAS-defined downstream-visible
    progress for runtime accept/reject. This delegates the content-shape
    boundary to [Agent_sdk.Response_shape.has_deliverable_content]; MASC should
    not add provider/model-specific accept rules here. Responses with no
    deliverable content are rejected before keeper response finalization,
    instead of failing later as "no textual reply". *)
val response_has_text_or_tool_progress : Agent_sdk.Types.api_response -> bool
