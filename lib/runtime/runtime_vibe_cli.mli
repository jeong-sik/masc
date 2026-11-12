(** Runtime_vibe_cli — run Mistral Vibe once in headless mode.

    One call is one [vibe] process. The prompt goes in a file passed with
    [--prompt-file] (m14), so its size is bounded neither by argv nor by a
    pipe Vibe might close before reading. The call gets a fresh directory
    that holds the prompt file and Vibe's [--output-dir]; this module removes
    it after the call. Both outputs are read with {!Runtime_vibe_headless}.

    RFC-vibe-official-client-lane §2.1 fixes the shape of a call: the [ask]
    agent, [--output json], and no auto-approval. §2.2 gives the child
    environment: [MISTRAL_API_KEY] is never passed. Without it [vibe-rs] read
    the key setup stored in the macOS Keychain (m4, m14). Whether [vibe-rs]
    reads [~/.vibe/.env] before the keychain, as [vibe-acp] does, is not
    measured.

    [export.json]'s [outcome] decides the result, and the exit code has to
    agree with {!Runtime_vibe_headless.exit_code_of_outcome}. *)

type config =
  { cli_path : string
  ; workdir : string
        (** Absolute directory the process starts in and Vibe's [--workdir]. *)
  ; trust_workdir : bool
        (** Pass [--trust]. Only for a root an operator has reviewed: Vibe then
            loads that directory's [.vibe], skills and agent files. *)
  ; model : string option  (** [--model] alias; [None] keeps Vibe's default. *)
  ; time_limit_s : int option
        (** [--time-limit] in whole seconds, at least 1. Vibe stops a run only
            after it has passed this limit (m5 ran 3.05 s on a 1 s limit) and
            still writes [export.json]. MASC then kills the process only if it
            is still running 30 s after the limit. [None] passes no limit and
            sets no MASC deadline; cancelling the calling fiber ends the
            call. *)
  }

val validate_config : config -> (unit, string) result

val child_environment : string array -> string array
(** The entries of an environment that a Vibe child may see: the names on a
    fixed list (home, user, locale, terminal, temp dirs, TLS certificates,
    proxies, XDG dirs). [MISTRAL_API_KEY] and every other provider or
    [VIBE_*] variable are not on it. A proxy URL passes as it is, user info
    included. *)

val argv : config -> output_dir:string -> prompt_file:string -> string list
(** The command line for one call. *)

(** Stdout of [--output json]. It was empty in the retained runs that did not
    finish (m3, m4, m5). *)
type transcript =
  | No_output
  | Entries of Runtime_vibe_headless.entry list

(** One process whose [export.json] agreed with its exit code. How it ended
    is [export.outcome]; a [usage_error] or a limit is a [run] too. *)
type run =
  { export : Runtime_vibe_headless.export
  ; transcript : transcript
  ; stderr_tail : string  (** Redacted end of stderr, cut at a UTF-8 boundary. *)
  }

type error =
  | Invalid_config of string
  | Native_tools_refused of Runtime_account_access.native_refusal
      (** This process runs no model turn with the tools of a Vibe agent.
          Nothing was spawned. *)
  | Process_runtime_unavailable
      (** The Eio process runtime is not initialized, so nothing was spawned. *)
  | Call_dir_failed of string
  | Spawn_refused of Process_eio.spawn_refusal
      (** No process existed: [cli_path] was not found or not executable, or
          [workdir] could not be opened. *)
  | Timed_out of
      { after_s : float option
      ; stderr_tail : string
      }
      (** [Some s]: MASC killed the process at its deadline. [None]: no
          deadline was set and the process exited 124 itself, which
          [Process_eio] reports the same way; Vibe 3.1.0 has no outcome with
          that code. *)
  | Signaled of
      { signal : int
      ; stderr_tail : string
      }
  | Stopped of
      { signal : int
      ; stderr_tail : string
      }
  | No_export of
      { exit_code : int
      ; stderr_tail : string
      }
      (** The process exited and wrote no [export.json]. Observed for an
          argument Vibe rejects (exit 1, m2). *)
  | Export_unreadable of Runtime_vibe_headless.error
  | Transcript_unreadable of
      { error : Runtime_vibe_headless.error
      ; usage : Runtime_vibe_headless.usage option
      }
      (** [export.json] agreed with the exit code but stdout did not decode. *)
  | Exit_code_mismatch of
      { process : int
      ; export : int
      ; usage : Runtime_vibe_headless.usage option
      }
      (** The process exit code differs from [export.json]'s [exit_code]. *)
  | Outcome_exit_mismatch of
      { outcome : Runtime_vibe_headless.outcome
      ; exit_code : int
      ; usage : Runtime_vibe_headless.usage option
      }
      (** The exit code is not the one Vibe gives this outcome. An
          unrecognized outcome is not checked. *)

val error_to_string : error -> string

val reported_usage : error -> Runtime_vibe_headless.usage option
(** The usage [export.json] reported, for the three errors that come after
    it was read; [None] for every other error and for an export with no
    usage. A run that disagreed with its export still spent those tokens. *)

val classify
  :  exit_code:int
  -> export_json:string option
  -> stdout:string
  -> stderr:string
  -> (run, error) result
(** Turn one finished process into a result. [export_json] is the content of
    [export.json], or [None] when the file does not exist. Pure; exposed for
    the tests and for callers that ran the process another way. *)

val run : host:Runtime_account_access.host_account -> config -> prompt:string -> (run, error) result
(** [host] is the start the access allows: Vibe reads the configuration of
    the host user (multi-account plan D3b). Validate [config], write the prompt into a new call directory, run the
    process with {!child_environment} and {!argv} through [Process_eio],
    classify it, and remove the call directory. The removal is an Eio switch
    release hook, which Eio runs with cancellation off, so a cancelled call
    removes it too. Needs an Eio fiber. *)
