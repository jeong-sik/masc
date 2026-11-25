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

    A plugin of the host can start observers beside a prompt: child sessions
    that call the model on their own. The parent's journal holds one
    [memory_reminder_child_session_linked] record per child and none of the
    child's counts. Each child keeps its own [session.jsonl] under the parent
    session's directory, and {!read_turn} adds the counts of the children that
    the prompt's runs linked.

    The format is the host's own and has no published schema. This module
    decodes the five record kinds it needs, requires the envelope
    [schema_version] and [payload_schema_version] it was checked against
    (muse acp 1.4.25), and reports anything else as an {!error}. It never
    substitutes zero for a count it could not read. *)

(* WORKAROUND: muse acp 1.4.25 sends no token counts over ACP, so the counts
   are read from the host's own journal, a file with no published schema.
   Root fix: the host reports usage in the session/prompt result, as the other
   ACP drivers do. Then this module goes, [driver_profile.usage_channel] goes,
   and the Muse profile uses [Usage_over_acp]. Until then a host version this
   module was not checked against gives a typed error, never counts. *)

(** What the host counted for a set of model calls. [input_tokens] includes
    [cache_read_tokens] and [output_tokens] includes [reasoning_tokens];
    {!read_turn} rejects a record whose counts contradict that. *)
type counts =
  { input_tokens : int
  ; output_tokens : int
  ; cache_read_tokens : int
  ; reasoning_tokens : int
  }

(** The observers the prompt's runs started. The host cancels some of them
    before their model request completes, and a cancelled request is in no
    journal, so a cancelled child adds nothing. *)
type observers =
  { counts : counts
        (** The requests and approval reviews in the journals of the children
            that had finished. *)
  ; cache_write_tokens : int
        (** Cache writes of the finished observers' model requests. *)
  ; finished : int
        (** Children whose journal holds a [terminal] record for every run it
            started. *)
  ; running : int
        (** Children whose journal has no run yet, or a run without a
            [terminal] record. Their counts may still grow, so none of them is
            added, and the next prompt does not add them either: its slice no
            longer holds their link record. *)
  ; without_journal : int
        (** Children the host linked without a journal path, as it does for
            its bundled [goal-reminder]. None of their counts is added. *)
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
  ; observers : observers
  }

(** The model requests, the approval reviews and the observers' counts of the
    turn added together: what the prompt cost the host. *)
val total : turn -> counts

(** Cache writes of the prompt's model requests and its finished observers'
    model requests added together. *)
val total_cache_write_tokens : turn -> int

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
  | Observer_journal of
      { path : string
      ; cause : error
      }  (** The journal of an observer the prompt linked could not be read. *)
  | Nested_observers
      (** The [cause] of an {!Observer_journal} only: the child's journal links
          observers of its own, which this module does not follow. *)

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

(** [read_turn mark] sums the counts of the runs started after [mark], and of
    the observers those runs linked. Only records ending in a newline count: a
    record the host is still writing is left out. A record that was half
    written at [mark] belongs to earlier activity and is skipped.

    A [child_session_log_path] is read relative to the session's directory. A
    path that is empty, absolute or contains a [..] segment is a
    {!Malformed_record}. A journal that several link records name is added
    once.

    An observer's journal that cannot be read, that does not exist, or that
    links observers of its own gives an {!Observer_journal} error for the whole
    turn: the prompt's own counts are not returned either. *)
val read_turn : mark -> (turn, error) result
