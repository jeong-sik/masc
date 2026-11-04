(** Completion of the input-holding steps entered by one command. Receipt
    evidence comes only from what the SDK declared for the step.
    The SDK documents no release acknowledgement. What it declares for an
    observed action is its receipt, [{popups?; dialog?: object}] in ego-lite
    page-model.ts: [dialog] is set from the dialog-opened error that unwound the
    driver, so an object receipt without it means the whole action ran. Raw
    calls such as [keyboard.type] and [mouse.up] swallow that error into void,
    so a void answer declares nothing. A separately verified native isolated
    binding interval may establish the raw SDK loop tail. It remains distinct
    from a native receipt and never proves physical freshness. Unbounded
    [Page.info()] or event samples cannot establish that interval.

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
  | Native_window_unconfirmed of Browser_ego_native_window.unconfirmed
  | Conflicting_evidence

(** The [kind] the SDK declares on an [ElementResolutionError]. *)
type resolution = Transient | Permanent

val resolution_to_wire : resolution -> string

(** Gestures that never resolve their target between a press and its release.
    The SDK throws [ElementResolutionError] with a declared [kind] when it
    cannot resolve the target ([src/element-resolver.ts] lines 28-35 at
    [citrolabs/ego-lite@12407167f84a]). In [src/driver/page-actions.ts] at that
    commit, [clickInPage] (234-385) resolves and checks the target before the
    first [mousePressed] and, for a double click, again only after the first
    [mouseReleased] returned; [dragAndDropInPage] (1070-1180) resolves both ends
    and their points before its [mousePressed] (1147). [dispatchMouseEvent] (1824-1839)
    swallows no error, so a dialog during a press unwinds as a dialog error,
    not as this one. A double click may still have finished its first click.
    On ego-browser 0.6.2.5 (Chromium 156,
    2026-11-04) eleven refusals of these three gestures (several matches, no
    match, hidden, disabled, covered, stale ref, missing drag source or
    destination) each threw that error, and the page received no pointer or
    mouse event. [press] is not one: [Page.press] sends its key outside the SDK
    input tracking, so a key may already be down when the same error arrives. *)
type refusable_gesture = Click | Double_click | Drag_and_drop

(** Completion evidence for one input-holding step. The SDK receipt answer,
    [Receipt_without_dialog], is an object receipt that has only the
    declared members, each once: [popups] (a list of [{label; targetId}] whose
    two members are strings that are not empty) and [dialog], and no [dialog].
    Only [answer_of_json] builds that receipt answer. [Native_window_tail]
    remains a separate Host-verified provenance. [Refused_before_press] is a
    refusable gesture whose SDK error declared it never resolved its target,
    so it holds nothing; only [answer_of_refusal] builds it. *)
type answer = private Receipt_without_dialog
  | Native_window_tail of Browser_ego_native_window.completion
  | Refused_before_press of resolution
  | Unreleased of unreleased

val receipt_contract : Yojson.Safe.t
(** Fixed field data for validating SDK input receipts before another action.
    Constructed from the same lists used by [answer_of_json]; it carries no
    input-release or operator authority. The host supplies it internally. *)

val answer_of_json : Yojson.Safe.t -> answer
(** Reads the answer an SDK call returned. It never yields [Never_returned];
    callers use [of_unreleased] when a step gave no answer. *)

val of_unreleased : unreleased -> answer
(** An answer that releases nothing. *)

val answer_of_refusal : refusable_gesture -> Yojson.Safe.t -> answer
(** Reads the [{name; kind}] of the error a refusable gesture threw. Exactly
    those two members, [name] ["ElementResolutionError"] and [kind]
    ["transient"] or ["permanent"], are [Refused_before_press]. Anything else
    is [Unreleased Never_returned]: the step gave no answer. *)

val answer_of_window : expected:Browser_ego_native_window.expected ->
  Browser_ego_native_window.completion -> (answer, string) result
(** Accept only exact verified invocation binding, never JSON/void flags. *)

(** Input-holding step evidence. Only [judge] builds a nonempty proof; native
    windows retain their private verified invocation identity. *)
type evidence = private Receipt_step of int
  | Window_step of { index:int; completion:Browser_ego_native_window.completion }
type proof = private Released_by_receipts of int list
  | Completed_by_evidence of evidence list
val window_bindings : proof -> Browser_ego_native_window.binding list
(** Reduced verified bindings for Input's current-pending/CAS check. *)

(** Nothing is left unconfirmed. [No_hold]: no input-holding step was entered,
    or every entered one was refused before its press, so there is nothing to
    release and the input keeps the readiness it had. *)
type settled = No_hold | Released of proof

type unconfirmed =
  | Step_not_released of { index : int; answer : unreleased }
      (** the first holding step without valid completion evidence *)
  | Held_by_script_report
      (** every answer is clean, but the script reports a held input *)

type t = Settled of settled | Unconfirmed of unconfirmed

val judge : (int * answer) list -> t
(** [judge answers] takes the input-holding steps in order. A step that
    appears twice counts once and keeps its first answer that releases nothing,
    so a later clean answer never undoes uncertainty. Identical native windows
    count once, but contradictory windows or receipt/window evidence at the
    same index refuse, and so does a refusal beside a receipt or window. A
    step refused before its press adds no evidence and holds nothing. All windows must agree on command/generation/source and
    authenticated index. [No_hold] preserves prior readiness. Receipt-only
    proof keeps its historical provenance; window bindings must additionally
    match actual Pending before Input settlement. *)

val describe : unconfirmed -> string
(** A short reason for an error message. *)
