(** Runtime_vibe_cli — run Mistral Vibe once in headless mode.

    One call is one [vibe -p] process. The prompt goes on stdin, the way the
    2026-11-07 run m13 sent it, so its size is not bounded by argv. The
    process writes [export.json] into a fresh output directory, which this
    module creates for the call and removes after it. Both outputs are read
    with {!Runtime_vibe_headless}.

    RFC-vibe-official-client-lane §2.1 fixes the shape of a call: the [ask]
    agent, [--output json], and no auto-approval. §2.2 gives the child
    environment: [MISTRAL_API_KEY] is never passed, so Vibe reads the
    credential setup stored in the OS keyring instead of the API key the
    server holds for the mistral HTTP lane.

    [export.json]'s [outcome] decides the result. The exit code only has to
    agree with it, as it did in every retained run: [finished] 0,
    [usage_error] 1, [infrastructure_failure] 2, and the three limits 3. *)

type config =
  { cli_path : string
  ; workdir : string
        (** Absolute directory the process starts in and Vibe's [--workdir]. *)
  ; trust_workdir : bool
        (** Pass [--trust]. Only for a root an operator has reviewed: Vibe then
            loads that directory's [.vibe], skills and agent files. *)
  ; model : string option  (** [--model] alias; [None] keeps Vibe's default. *)
  ; max_turns : int  (** [--max-turns], at least 1. *)
  ; time_limit_s : int
        (** [--time-limit] in whole seconds, at least 1. Vibe stops a run only
            after it has passed this limit (m5 ran 3.05 s on a 1 s limit). *)
  ; process_timeout_s : float
        (** When MASC kills the process. It must be longer than
            [time_limit_s], so Vibe's own limit ends a slow run first and
            still writes [export.json]. *)
  }

val validate_config : config -> (unit, string) result

val child_environment : string array -> string array
(** The entries of an environment that a Vibe child may see: the names on a
    fixed list (home, user, locale, terminal, temp dirs, TLS certificates,
    XDG dirs). [MISTRAL_API_KEY] and every other provider or [VIBE_*]
    variable are not on it. *)

val argv : config -> output_dir:string -> string list
(** The command line for one call. It ends with [-p] and no value, so Vibe
    reads the prompt from stdin. *)

type limit =
  | Deadline
  | Token_limit
  | Turn_limit

(** Stdout of [--output json]. Vibe wrote nothing to stdout in every retained
    run that ended before a session started (m2, m3, m4, m5). *)
type transcript =
  | No_output
  | Entries of Runtime_vibe_headless.entry list

type run =
  { export : Runtime_vibe_headless.export
  ; transcript : transcript
  ; stderr_tail : string  (** Redacted end of stderr, cut at a UTF-8 boundary. *)
  }

type completed =
  | Finished of run
  | Stopped_at_limit of
      { limit : limit
      ; run : run
      }
  | Usage_error of run
  | Infrastructure_failure of run
  | Unrecognized_outcome of
      { outcome : string
      ; run : run
      }
      (** An [outcome] the decoder does not know. The exit code was not
          checked against it. *)

type error =
  | Invalid_config of string
  | Process_runtime_unavailable
      (** The Eio process runtime is not initialized, so nothing was spawned. *)
  | Output_dir_failed of string
  | Timed_out of { after_s : float }  (** MASC killed it at [process_timeout_s]. *)
  | Signaled of int
  | Stopped of int
  | No_export of
      { exit_code : int
      ; stderr_tail : string
      }
      (** The process exited and wrote no [export.json]. Observed for an
          argument Vibe rejects (exit 1, m2). *)
  | Export_unreadable of Runtime_vibe_headless.error
  | Transcript_unreadable of Runtime_vibe_headless.error
  | Exit_code_mismatch of
      { process : int
      ; export : int
      }
      (** The process exit code differs from [export.json]'s [exit_code]. *)
  | Outcome_exit_mismatch of
      { outcome : Runtime_vibe_headless.outcome
      ; exit_code : int
      }
      (** The exit code is not the one this outcome had in the retained runs. *)

val error_to_string : error -> string

val classify
  :  exit_code:int
  -> export_json:string option
  -> stdout:string
  -> stderr:string
  -> (completed, error) result
(** Turn one finished process into a result. [export_json] is the content of
    [export.json], or [None] when the file does not exist. Pure; exposed for
    the tests and for callers that ran the process another way. *)

val run : config -> prompt:string -> (completed, error) result
(** Validate [config], create the output directory, run the process with
    {!child_environment} and {!argv} through [Process_eio] (Eio only, no Unix
    fallback), classify it, and remove the output directory. *)
