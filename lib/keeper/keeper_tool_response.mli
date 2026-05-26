(** Keeper_tool_response - provider response acceptance and keeper reply text
    normalization. *)

(** Keep [text] when non-blank; otherwise synthesize a
    "Completed without a textual reply. Tools used: ..." line if [tool_names]
    is non-empty, else error. *)
val normalize_response_text
  :  text:string
  -> tool_names:string list
  -> unit
  -> (string, string) result

(** [true] when a provider response carries usable keeper progress for cascade
    accept/reject: non-blank text, ToolUse, or a non-terminal stop reason.
    Empty [end_turn] responses are rejected so cascade can try the next
    candidate instead of failing later as "no textual reply". *)
val response_has_text_or_tool_progress : Agent_sdk.Types.api_response -> bool
