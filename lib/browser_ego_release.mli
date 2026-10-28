(** Whether the keys or buttons an input-holding step may have pressed are
    released. The answer comes only from what the SDK declared for the step.
    The SDK documents no release acknowledgement. What it declares for an
    observed action is its receipt, [{popups?; dialog?: object}] in ego-lite
    page-model.ts: [dialog] is set from the dialog-opened error that unwound the
    driver, so an object receipt without it means the whole action ran. Raw
    calls such as [keyboard.type] and [mouse.up] swallow that error into void,
    so a void answer declares nothing. [Page.info()] and the Page's event buffer
    are samples of the page, not answers of the SDK, and are never evidence.

    This premise was read at [citrolabs/ego-lite@aecc5831fc5a] in
    [package/ego-browser/src/page-model.ts]. The line numbers below hold only
    at that commit: the receipt type at lines
    411-414, where [dialog] is filled at 2777-2784, and the raw calls at
    512-568 and 2674-2687; and in [src/browser-runtime.ts], where
    [PageDialogOpenedError] always carries an object [dialog] (115-146).
    When the Ego Lite version the Add-on supports changes, read those places
    again before trusting this module. [docs/guides/ego-native-workflow.md]
    keeps the permalinks. *)

(** The answers that release nothing. Anyone may build them. *)
type unreleased =
  | Receipt_with_dialog  (** an object receipt whose [dialog] is an object *)
  | Void_answer  (** [null] *)
  | Undeclared_answer
      (** anything else: a non-object, a member the SDK does not declare or a
          repeated member, a malformed [popups], or a [dialog] that is not an
          object *)
  | Never_returned  (** the step was entered and gave no answer *)

(** What the SDK declared for one input-holding step. The one answer that
    releases, [Receipt_without_dialog], is an object receipt that has only the
    declared members, each once: [popups] (a list of [{label; targetId}] whose
    two members are strings that are not empty) and [dialog], and no [dialog].
    Only [answer_of_json] builds it. *)
type answer = private Receipt_without_dialog | Unreleased of unreleased

val answer_of_json : Yojson.Safe.t -> answer
(** Reads the answer an SDK call returned. It never yields [Never_returned];
    callers use [of_unreleased] when a step gave no answer. *)

val of_unreleased : unreleased -> answer
(** An answer that releases nothing. *)

(** The input-holding steps, by index, whose answer released them. It is never
    empty, and only [judge] builds it. *)
type proof = private Released_by_receipts of int list

(** Nothing is left unconfirmed. [No_hold]: no input-holding step was entered,
    so there is nothing to release and the input keeps the readiness it had. *)
type settled = No_hold | Released of proof

type unconfirmed =
  | Step_not_released of { index : int; answer : unreleased }
      (** the first holding step whose answer is not [Receipt_without_dialog] *)
  | Held_by_script_report
      (** every answer is clean, but the script reports a held input *)

type t = Settled of settled | Unconfirmed of unconfirmed

val judge : (int * answer) list -> t
(** [judge answers] takes the input-holding steps in order. A step that
    appears twice counts once and keeps its first answer that releases nothing,
    so a later clean answer never undoes a dialog, and a proof never lists a
    step twice. It is [Settled No_hold] for none, [Settled (Released _)] when
    every answer is [Receipt_without_dialog], and otherwise [Unconfirmed]
    naming the first answer that is not. The caller passes what the SDK
    returned; a proof is not tied to the call it came from. *)

val describe : unconfirmed -> string
(** A short reason for an error message. *)
