(** Reading an Antigravity account's usage windows through the official CLI,
    without a turn.

    agy 1.1.11 and later answer [agy -p "/usage" --output-format json] in print
    mode without starting an agent turn or spending quota. The read runs in a
    disposable HOME seeded from the account's OAuth file, the way the context
    observation does ({!Runtime_antigravity_context}), so it never shares a
    HOME, token refresh or conversation with a Keeper's turn. The HOME is
    removed when the read ends. *)

val read_timeout_s : float
(** The bound on each subprocess of one read: the version probe and the
    [/usage] command. *)

val minimum_version : int * int * int
(** The first agy release whose print mode answers [/usage] without a turn. *)

type phase =
  | Version_probe  (** [agy --version]. *)
  | Usage_command  (** [agy -p "/usage" --output-format json]. *)

type error =
  | Private_home_unavailable
  | Command_refused of
      { phase : phase
      ; detail : string
      }  (** No process ran: the spawn was refused. *)
  | Command_failed of
      { phase : phase
      ; status : Unix.process_status
      ; stderr_tail : string
      }
  | Version_unreadable of string
      (** [--version] did not print [MAJOR.MINOR.PATCH]; carries what it
          printed, trimmed. *)
  | Version_too_old of string
      (** Below {!minimum_version}: [/usage] would be a turn, so it is not
          sent. *)
  | Output_not_json
  | Decode_failed of Runtime_provider_usage_window.decode_error

val error_to_string : error -> string

val parse_version : string -> (int * int * int) option
(** [MAJOR.MINOR.PATCH] after trimming, all three decimal; anything else is
    [None]. *)

val read
  :  cli_path:string
  -> oauth_source:string
  -> (Runtime_provider_usage_window.report, error) result
(** Prepare a disposable HOME from [oauth_source], check the CLI version, run
    [/usage], and decode its JSON with
    {!Runtime_provider_usage_window.decode_antigravity_usage}. Nothing is
    recorded here. *)
