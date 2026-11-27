(** Compactions and the ending of one [kimi acp] prompt, read from the host's
    session record.

    [kimi acp] (Kimi Code 2.7.3) compacts a session on its own when the
    context reaches the share of the window set in its settings. Over ACP it
    says so only as message text, and it sends one [usage_update] per prompt,
    after the prompt's response. A prompt that compacted and then grew past the
    count the previous prompt ended at shows no drop in that count. On
    2026-11-27 a Keeper's session compacted at 01:51 KST, its prompt ended at
    02:07, and the settlement kept the 34 held entries, so the next prompt
    would send only what had changed against a session that held a summary.

    The host writes every event of a session to
    [<home>/sessions/<workspace directory>/<session id>/agents/main/wire.jsonl]:
    one JSON record per line, appended in order. The first record is a
    [metadata] record carrying the format's [protocol_version]. Each compaction
    writes a [context.apply_compaction] record when the summary replaces the
    context, between its [full_compaction.begin] and [full_compaction.complete]
    records. A prompt's compactions are the [context.apply_compaction] records
    the file gained between {!mark}, taken before [session/prompt] is sent, and
    {!compactions}, taken after it returns. The mark {!compactions} returns
    lets the next prompt count from there, so a prompt that failed or was
    cancelled before its count leaves its records to the next one.

    The format is the host's own and has no published schema. This module
    requires the [protocol_version] it was checked against and reports
    anything else as an {!error}. *)

(* WORKAROUND: kimi acp sends no typed signal when it compacts a session and
   counts the session once per prompt, after the response, so the record of a
   compaction is read from the host's own file. Root fix: the host sends a
   usage_update when a compaction completes (or after each model request), as
   Mistral Vibe does; then the drop in usage_update.used that the other hosts
   show is enough, and this module and [compaction_record] go. *)

type error =
  | Home_unavailable
      (** [KIMI_CODE_HOME] is set to a relative path, or it is unset or empty
          and [HOME] is not an absolute path. *)
  | Session_id_invalid of string
      (** The id could name something other than one directory entry. *)
  | Session_record_not_found of
      { searched : string
      ; session_id : string
      }
  | Session_record_ambiguous of
      { session_id : string
      ; paths : string list
      }  (** More than one workspace directory holds the session. *)
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Record_shrank of
      { path : string
      ; marked_at : int
      ; size : int
      }  (** The file is shorter than it was when the prompt was sent. *)
  | Slice_too_large of { bytes : int }
  | Unsupported_protocol of
      { path : string
      ; found : string option
      ; supported : string
      }  (** The first record is not [metadata] with the checked version. *)
  | Malformed_record of
      { byte_offset : int
      ; detail : string
      }

val error_to_string : error -> string

(** The directory that holds the host's sessions. *)
type root

(** [root_of_environment env] mirrors the rule the host states for its home:
    [$KIMI_CODE_HOME] when it is set and not empty, else [$HOME/.kimi-code].
    [env] is the [KEY=value] array the host was started with. *)
val root_of_environment : string array -> (root, error) result

val root_directory : root -> string

(** The record's length when a prompt was sent. *)
type mark

(** [mark root ~session_id] finds the session's record, checks its
    [protocol_version] and records its length. Call it before
    [session/prompt] is sent. *)
val mark : root -> session_id:string -> (mark, error) result

(** How the host ended a prompt, from its [turn.ended] record.

    Over ACP a prompt the host could not run still answers
    [{"stopReason":"end_turn"}], with no error and no message. On 2026-11-27
    the account's weekly usage limit was reached and every [kimi acp] prompt
    came back that way; the host wrote the cause only here, as
    [{"reason":"failed","error":{"code":"provider.api_error","message":
    "You've reached your weekly (7-day) usage limit. ..."}}]. *)
type turn_end =
  | Turn_completed
  | Turn_cancelled
  | Turn_failed of
      { code : string  (** The host's own code, such as [provider.api_error]. *)
      ; message : string
      ; status : int option
          (** [error.details.statusCode]: the provider's HTTP status, when the
              host recorded one. *)
      }

type prompt_record =
  { compactions : int  (** [context.apply_compaction] records. *)
  ; turn_end : turn_end option
      (** The [turn.ended] record of the last prompt that started after the
          mark ([turn.prompt]); [None] when the host wrote none for it. *)
  }

(** [read_prompt mark] reads the records written after [mark] and returns
    what they say about the prompt, with the mark the next read starts from:
    the end of the last whole record read. Only records ending in a newline
    count: a record the host is still writing is left out and read from the
    next mark. A record that was half written at [mark] belongs to earlier
    activity and is skipped. A [turn.ended] record with a reason other than
    [completed], [cancelled] or [failed], or a [failed] one without
    [error.code] and [error.message], is a {!Malformed_record}. *)
val read_prompt : mark -> (prompt_record * mark, error) result
