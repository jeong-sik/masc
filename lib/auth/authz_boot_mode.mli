(* HIGH-RISK-UNREVIEWED: this module decides the account mode a server boots in.
   A wrong answer boots a rolled-back multi-account installation as a single
   user, or boots one with auth turned off. *)

(** The boot judgment of the account mode (multi-account design 5.1).

    The [account_mode] of [config.json] is a request. The mode is decided once
    at boot from three things read before it: the request, the mode that the
    last mode event of the authorization log made, and the external high-water
    mark ({!Authz_high_water}). Every reason to refuse is returned, not only the
    first.

    It reads no file and writes none. {!Authz_boot_mode_read} reads the files,
    builds an {!input}, and says what the boot does with the answer. In particular {!Activation_requested} is
    an answer, not a permission: it says that a [Fresh_bootstrap] is the only
    thing this installation may do. *)

(** The [account_mode] member of [config.json], read on its own so that a file
    whose other fields are wrong still says which mode it asks for. *)
type requested =
  | Not_set  (** No member, no file, or a file that is not a JSON object. *)
  | Requested of Masc_domain.account_mode
  | Unknown_value of string
      (** The member holds another value: [null], a number, an object, another
          case, or it appears twice. The text is the JSON of the value, for the
          message only. *)

(** What the authorization log says about the mode. *)
type log_mode =
  | Log_unreadable of string
      (** The log exists and cannot be opened or checked. A last line that never
          ended is not this: it is cut when the log is opened. *)
  | No_mode_event
      (** No log, or a log with no lines. A log that holds records and no mode
          event is {!Log_unreadable}: a [Fresh_bootstrap] is its first record. *)
  | Made_multi_account  (** The last mode event is [Fresh_bootstrap] or [Reactivate]. *)
  | Made_off of Authz_state.t
      (** The last mode event is [Off]. The state is the one the log replayed
          to: what the accounts recorded before they were turned off. *)

(** What the mode of a log that opened says. *)
val of_state : Authz_state.t -> log_mode

(** The external high-water mark. *)
type high_water =
  | Store_unreadable of string
      (** The install record or the external store it names exists and cannot be
          opened or read. *)
  | Judged of Authz_high_water.t

(** The other fields of [config.json], as the full decoder reads them. *)
type settings =
  | Settings_read of
      { enabled : bool
      ; require_token : bool
      }
  | Settings_unreadable of string
      (** The full decoder refused the file. A single-user boot keeps the
          behavior it has without this module: a request that reads the config
          gets 503. *)

type input =
  { requested : requested
  ; log_mode : log_mode
  ; high_water : high_water
  ; settings : settings
  ; anonymous_mutations : bool
        (** [MASC_ALLOW_ANONYMOUS_MUTATIONS] is on. *)
  }

type mode =
  | Single_user  (** The behavior without accounts, as before this module. *)
  | Single_user_after_off of Authz_state.t
      (** The log made [Off], the external store matches it, and the config
          does not ask for [Multi_account] (row 4): the behavior without
          accounts, with the records of the accounts in this state kept
          read-only (design 10.5). *)
  | Activation_requested
      (** [Multi_account] is asked for and nothing was set up yet. Only the
          host-local [Fresh_bootstrap] may run. *)
  | Multi_account
  | Multi_account_uncertain
      (** [Multi_account] with a high-water mark that is absent, does not match,
          or cannot be read: [AuthorizationUncertain] (design 8.2, 8.4). *)

type refusal =
  | Unknown_account_mode of string
  | Authorization_log_unreadable of string
  | Rewound_before_bootstrap
      (** No mode event, while the external store says that one was answered:
          a restore took the log back to before the bootstrap. *)
  | Downgraded_from_multi_account
      (** The log made [Multi_account] and the config does not ask for it. *)
  | Reactivation_not_ready
      (** The log made [Off] and the config asks for [Multi_account]: a
          reactivation, which needs the recovery procedure of design 10.5. *)
  | Rewound_after_off
      (** The log made [Off] and the external store does not match it: the base
          path may have been restored to before a later reactivation. *)
  | External_store_unreadable of string
      (** The install record or the external store cannot be read, where the
          table needs to know whether the store holds an installation: with no
          mode event (rows 2 and 6) and after [Off] (row 10). *)
  | Auth_disabled_in_multi_account
  | Token_not_required_in_multi_account
  | Anonymous_mutations_in_multi_account
  | Auth_settings_unreadable_in_multi_account of string

(** What a request asks a boot to run. No member and [Single_user] are one
    answer: the config column of the table (design 5.1). *)
type asked =
  | Asks_single_user
  | Asks_multi_account

(* HIGH-RISK-UNREVIEWED: the one reading of the request. *)

(** The request as {!judge} reads it, for a caller that has the request and
    neither the log nor the store. {!Unknown_value} is
    [Error (Unknown_account_mode _)], the refusal {!judge} gives for it, so no
    caller reads such a config as one that asks for a single user. [Ok] says
    what is asked and nothing of what a boot answers: the log and the store
    decide that. *)
val asked : requested -> (asked, refusal) result

val judge : input -> (mode, refusal * refusal list) result
val mode_to_string : mode -> string
val refusal_to_string : refusal -> string
