(** Token counts of one [muse acp] prompt, read from the host's session
    journal.

    [muse acp] 1.4.25 sends no token counts over ACP. The [session/prompt]
    result holds [stopReason] only, and [usage_update] holds the context
    window's [used] and [size]. The host does write the counts of every model
    request and of every approval review it runs to
    [<data root>/muse/sessions/YYYY/MM/DD/<session id>/session.jsonl]: one JSON
    record per line, appended in order. A prompt's counts are what that file
    gained between {!mark}, taken before [session/prompt] is sent, and
    {!read_turn}, taken after it returns.

    The format is the host's own and has no published schema. This module
    decodes the four record kinds it needs, requires the envelope
    [schema_version] and [payload_schema_version] it was checked against
    (muse acp 1.4.25), and reports anything else as an {!error}. It never
    substitutes zero for a count it could not read. *)

(** What the host counted for a set of model calls. [input_tokens] includes
    [cache_read_tokens] and [output_tokens] includes [reasoning_tokens];
    {!read_turn} rejects a record whose counts contradict that. *)
type counts =
  { input_tokens : int
  ; output_tokens : int
  ; cache_read_tokens : int
  ; reasoning_tokens : int
  }

type turn =
  { main : counts
        (** The model requests of the prompt's runs, one [model_completed]
            record each. *)
  ; main_cache_write_tokens : int
        (** Cache writes of those requests. A review record carries no
            cache-write count. *)
  ; main_requests : int
  ; last_request_input_tokens : int option
        (** [input_tokens] of the last request: the size of the context it was
            sent. [None] when no request completed. *)
  ; review : counts
        (** The host's approval reviews, one [automated_review_completed]
            record per MCP tool call it checked. Each is a model call of its
            own. *)
  ; reviews : int
  }

(** The model requests and the approval reviews of the turn added together:
    what the prompt cost the host. *)
val total : turn -> counts

type error =
  | Data_root_unavailable
      (** Neither [XDG_DATA_HOME] nor [HOME] is an absolute directory. *)
  | Session_id_invalid of string
      (** The id could name something other than one directory entry. *)
  | Session_log_not_found of
      { searched : string
      ; session_id : string
      }
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Journal_shrank of
      { path : string
      ; marked_at : int
      ; size : int
      }  (** The file is shorter than it was when the prompt was sent. *)
  | Slice_too_large of { bytes : int }
  | Unsupported_schema of
      { record : string
      ; found : int
      ; supported : int
      }
  | Malformed_record of
      { byte_offset : int
      ; detail : string
      }
  | No_run_in_slice  (** The prompt added no [started] record. *)
  | Run_not_terminated of { run_id : string }
      (** A run the prompt started has no [terminal] record yet, so its counts
          may be incomplete. *)

val error_to_string : error -> string

(** The directory that holds the host's sessions. *)
type root

(** [root_of_environment env] mirrors the rule the host states for its own
    data directory: [$XDG_DATA_HOME/muse] when that is an absolute path, else
    [$HOME/.local/share/muse]. [env] is the [KEY=value] array the host was
    started with. *)
val root_of_environment : string array -> (root, error) result

val root_directory : root -> string

(** The journal's length when a prompt was sent. *)
type mark

(** [mark root ~session_id] finds the session's journal and records its
    length. Call it before [session/prompt] is sent. *)
val mark : root -> session_id:string -> (mark, error) result

(** [read_turn mark] sums the counts of the runs started after [mark]. Only
    records ending in a newline count: a record the host is still writing is
    left out. A record that was half written at [mark] belongs to earlier
    activity and is skipped. *)
val read_turn : mark -> (turn, error) result
