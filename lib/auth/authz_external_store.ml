(* HIGH-RISK-UNREVIEWED: this module reads and writes the file of the external
   store. A line it writes decides whether a boot trusts the authorization log,
   and a line that does not read back stops every later start. *)

(* See authz_external_store.mli. *)

open Authz_types
open Authz_records
module Hash = Authz_record.Hash

let ( let* ) = Result.bind

module Change = struct
  type authz_event =
    | Grant
    | Revoke
    | Disable
    | Delete
    | Block
    | Purge
    | Policy_revoke
    | Credential_replace

  type mode_event =
    | Fresh_bootstrap
    | Off
    | Reactivate

  type t =
    | Authz of
        { event : authz_event
        ; subject : Subject.t
        }
    | Mode of
        { event : mode_event
        ; workspace_id : Workspace_id.t
        }

  (* The label functions below name every constructor, so the compiler stops at
     a new one. These two lists are what a label is read back through: a
     constructor that is missing here is written, read back as
     [Invalid_change], and refused by [append] with nothing written. *)
  let authz_events =
    [ Grant; Revoke; Disable; Delete; Block; Purge; Policy_revoke; Credential_replace ]
  ;;

  let mode_events = [ Fresh_bootstrap; Off; Reactivate ]

  let authz_event_label = function
    | Grant -> "grant"
    | Revoke -> "revoke"
    | Disable -> "disable"
    | Delete -> "delete"
    | Block -> "block"
    | Purge -> "purge"
    | Policy_revoke -> "policy_revoke"
    | Credential_replace -> "credential_replace"
  ;;

  let mode_event_label = function
    | Fresh_bootstrap -> "fresh_bootstrap"
    | Off -> "off"
    | Reactivate -> "reactivate"
  ;;

  let authz_event_of_label label =
    List.find_opt (fun event -> String.equal (authz_event_label event) label) authz_events
  ;;

  let mode_event_of_label label =
    List.find_opt (fun event -> String.equal (mode_event_label event) label) mode_events
  ;;

  let equal a b =
    match a, b with
    | Authz a, Authz b -> a.event = b.event && Subject.equal a.subject b.subject
    | Mode a, Mode b -> a.event = b.event && Workspace_id.equal a.workspace_id b.workspace_id
    | (Authz _ | Mode _), (Authz _ | Mode _) -> false
  ;;

  let authz_event_is_reduction = function
    | Grant -> false
    | Revoke | Disable | Delete | Block | Purge | Policy_revoke | Credential_replace -> true
  ;;

  let is_reduction = function
    | Authz { event; subject = _ } -> authz_event_is_reduction event
    | Mode { event = Fresh_bootstrap | Off | Reactivate; workspace_id = _ } -> false
  ;;

  let to_string = function
    | Authz { event; subject } ->
      Printf.sprintf "%s of %s" (authz_event_label event) (Subject.to_string subject)
    | Mode { event; workspace_id } ->
      Printf.sprintf "%s of workspace %s" (mode_event_label event) (Workspace_id.to_string workspace_id)
  ;;
end

type intent =
  { previous_record_hash : Hash.t
  ; intended_next_record_digest : Hash.t
  ; change : Change.t
  }

type entry =
  | Intent_pending of intent
  | Committed of { record_hash : Hash.t }
  | Aborted_intent of intent

let intent_equal a b =
  Hash.equal a.previous_record_hash b.previous_record_hash
  && Hash.equal a.intended_next_record_digest b.intended_next_record_digest
  && Change.equal a.change b.change
;;

let entry_equal a b =
  match a, b with
  | Intent_pending a, Intent_pending b -> intent_equal a b
  | Committed a, Committed b -> Hash.equal a.record_hash b.record_hash
  | Aborted_intent a, Aborted_intent b -> intent_equal a b
  | Intent_pending _, (Committed _ | Aborted_intent _)
  | Committed _, (Intent_pending _ | Aborted_intent _)
  | Aborted_intent _, (Intent_pending _ | Committed _) -> false
;;

(* The workspace that a committed change sets up, when the change is a
   [Fresh_bootstrap]. *)
let bootstrapped_workspace = function
  | Change.Mode { event = Change.Fresh_bootstrap; workspace_id } -> Some workspace_id
  | Change.Mode { event = Change.Off | Change.Reactivate; workspace_id = _ } -> None
  | Change.Authz { event = _; subject = _ } -> None
;;

module State = struct
  type t =
    { entries : int
    ; pending : intent option
    ; last_committed : Hash.t option
    ; aborted : intent list  (** Newest first. *)
    ; workspace_id : Workspace_id.t option
    }

  let empty =
    { entries = 0; pending = None; last_committed = None; aborted = []; workspace_id = None }
  ;;

  let pending state = state.pending
  let last_committed state = state.last_committed
  let aborted state = List.rev state.aborted
  let workspace_id state = state.workspace_id
end

type violation =
  | Intent_while_pending
  | Committed_without_intent
  | Committed_other_digest
  | Aborted_without_intent
  | Aborted_other_intent
  | Intent_before_bootstrap
  | Bootstrap_already_committed
  | Workspace_mismatch

let violation_to_string = function
  | Intent_while_pending -> "an intent is already pending"
  | Committed_without_intent -> "no intent is pending to commit"
  | Committed_other_digest -> "the hash is not the one that the pending intent named"
  | Aborted_without_intent -> "no intent is pending to abort"
  | Aborted_other_intent -> "it is not the pending intent"
  | Intent_before_bootstrap -> "only a fresh bootstrap can come before one is committed"
  | Bootstrap_already_committed -> "a fresh bootstrap is already committed"
  | Workspace_mismatch -> "the workspace is not the one of the committed bootstrap"
;;

(* What an intent may be about, given whether a fresh bootstrap is committed
   (design 5.1 and 8.4: a store starts with a fresh bootstrap, and the workspace
   of the committed one is the only valid one). Every pair is named. *)
let check_change (state : State.t) (change : Change.t) =
  match state.State.workspace_id, change with
  | None, Change.Mode { event = Change.Fresh_bootstrap; workspace_id = _ } -> Ok ()
  | None, Change.Mode { event = Change.Off | Change.Reactivate; workspace_id = _ }
  | None, Change.Authz { event = _; subject = _ } -> Error Intent_before_bootstrap
  | Some _, Change.Mode { event = Change.Fresh_bootstrap; workspace_id = _ } ->
    Error Bootstrap_already_committed
  | Some bootstrapped, Change.Mode { event = Change.Off | Change.Reactivate; workspace_id } ->
    if Workspace_id.equal bootstrapped workspace_id then Ok () else Error Workspace_mismatch
  | Some _, Change.Authz { event = _; subject = _ } -> Ok ()
;;

(* The rules of the file. [Intent_pending] needs the file to be at rest and a
   change that fits the file, and an answer needs the intent it answers. *)
let check (state : State.t) entry =
  match entry, state.State.pending with
  | Intent_pending _, Some _ -> Error Intent_while_pending
  | Intent_pending intent, None -> check_change state intent.change
  | Committed _, None -> Error Committed_without_intent
  | Committed { record_hash }, Some pending ->
    if Hash.equal record_hash pending.intended_next_record_digest
    then Ok ()
    else Error Committed_other_digest
  | Aborted_intent _, None -> Error Aborted_without_intent
  | Aborted_intent intent, Some pending ->
    if intent_equal intent pending then Ok () else Error Aborted_other_intent
;;

(* What the file adds up to once the entry is in it. The entry has passed
   [check]. *)
let advance (state : State.t) entry : State.t =
  let state = { state with State.entries = state.State.entries + 1 } in
  match entry with
  | Intent_pending intent -> { state with State.pending = Some intent }
  | Committed { record_hash } ->
    let workspace_id =
      match state.State.pending with
      | None -> state.State.workspace_id
      | Some pending ->
        (match bootstrapped_workspace pending.change with
         | Some workspace_id -> Some workspace_id
         | None -> state.State.workspace_id)
    in
    { state with State.pending = None; last_committed = Some record_hash; workspace_id }
  | Aborted_intent intent ->
    { state with State.pending = None; aborted = intent :: state.State.aborted }
;;

let describe_state (state : State.t) =
  Printf.sprintf
    "%d entries, %s"
    state.State.entries
    (match state.State.pending with
     | None -> "no intent pending"
     | Some intent -> "pending: " ^ Change.to_string intent.change)
;;

(* ---- the text of a line ---- *)

(* Every string goes through [Authz_body.string_literal], the one escape
   function of the authorization layer, even though an identifier or a hash has
   no character that needs one. *)
let literal = Authz_body.string_literal
let hash_text hash = literal (Hash.to_hex hash)

let subject_text = function
  | Subject.Grant id -> {|{"type":"grant","id":|} ^ literal (Grant_id.to_string id) ^ "}"
  | Subject.Credential id ->
    {|{"type":"credential","id":|} ^ literal (Provider_account_id.to_string id) ^ "}"
  | Subject.Principal principal ->
    {|{"type":"principal","principal":|} ^ Authz_record.principal_text principal ^ "}"
  | Subject.Runtime id -> {|{"type":"runtime","id":|} ^ literal (Runtime_id.to_string id) ^ "}"
;;

let change_text = function
  | Change.Authz { event; subject } ->
    {|{"type":"authz","event":|}
    ^ literal (Change.authz_event_label event)
    ^ {|,"subject":|}
    ^ subject_text subject
    ^ "}"
  | Change.Mode { event; workspace_id } ->
    {|{"type":"mode","event":|}
    ^ literal (Change.mode_event_label event)
    ^ {|,"workspace_id":|}
    ^ literal (Workspace_id.to_string workspace_id)
    ^ "}"
;;

let intent_text kind intent =
  {|{"kind":|}
  ^ literal kind
  ^ {|,"previous_record_hash":|}
  ^ hash_text intent.previous_record_hash
  ^ {|,"intended_next_record_digest":|}
  ^ hash_text intent.intended_next_record_digest
  ^ {|,"change":|}
  ^ change_text intent.change
  ^ "}"
;;

let to_line = function
  | Intent_pending intent -> intent_text "intent_pending" intent
  | Committed { record_hash } ->
    {|{"kind":"committed","record_hash":|} ^ hash_text record_hash ^ "}"
  | Aborted_intent intent -> intent_text "aborted_intent" intent
;;

(* ---- reading a line ---- *)

type line_error =
  | Not_json
  | Unexpected_shape
  | Unknown_kind of string
  | Invalid_hash
  | Invalid_change
  | Breaks_a_rule of violation
  | Non_canonical

let line_error_to_string = function
  | Not_json -> "not json"
  | Unexpected_shape -> "not exactly the members of an entry, in order"
  | Unknown_kind label -> Printf.sprintf "unknown kind %S" label
  | Invalid_hash -> "a hash is not 64 lowercase hex characters"
  | Invalid_change -> "the change is not one of the shapes of a change"
  | Breaks_a_rule violation -> violation_to_string violation
  | Non_canonical -> "valid entry, but not the line this module writes for it"
;;

let subject_of_json = function
  | `Assoc [ ("type", `String "grant"); ("id", `String id) ] ->
    Option.map (fun id -> Subject.Grant id) (Result.to_option (Grant_id.of_string id))
  | `Assoc [ ("type", `String "credential"); ("id", `String id) ] ->
    Option.map
      (fun id -> Subject.Credential id)
      (Result.to_option (Provider_account_id.of_string id))
  | `Assoc [ ("type", `String "principal"); ("principal", principal) ] ->
    Option.map (fun principal -> Subject.Principal principal) (Authz_record.principal_of_json principal)
  | `Assoc [ ("type", `String "runtime"); ("id", `String id) ] ->
    Option.map (fun id -> Subject.Runtime id) (Result.to_option (Runtime_id.of_string id))
  | _ -> None
;;

let change_of_json = function
  | `Assoc [ ("type", `String "authz"); ("event", `String event); ("subject", subject) ] ->
    (match Change.authz_event_of_label event, subject_of_json subject with
     | Some event, Some subject -> Some (Change.Authz { event; subject })
     | None, _ | _, None -> None)
  | `Assoc [ ("type", `String "mode"); ("event", `String event); ("workspace_id", `String id) ] ->
    (match Change.mode_event_of_label event, Result.to_option (Workspace_id.of_string id) with
     | Some event, Some workspace_id -> Some (Change.Mode { event; workspace_id })
     | None, _ | _, None -> None)
  | _ -> None
;;

let intent_of_members ~previous ~digest ~change =
  match Hash.of_hex previous, Hash.of_hex digest with
  | Some previous_record_hash, Some intended_next_record_digest ->
    (match change_of_json change with
     | Some change -> Ok { previous_record_hash; intended_next_record_digest; change }
     | None -> Error Invalid_change)
  | None, _ | _, None -> Error Invalid_hash
;;

let entry_of_json json =
  match json with
  | `Assoc (("kind", `String kind) :: members) ->
    (match kind, members with
     | ( "intent_pending"
       , [ ("previous_record_hash", `String previous)
         ; ("intended_next_record_digest", `String digest)
         ; ("change", change)
         ] ) ->
       Result.map (fun intent -> Intent_pending intent) (intent_of_members ~previous ~digest ~change)
     | ( "aborted_intent"
       , [ ("previous_record_hash", `String previous)
         ; ("intended_next_record_digest", `String digest)
         ; ("change", change)
         ] ) ->
       Result.map (fun intent -> Aborted_intent intent) (intent_of_members ~previous ~digest ~change)
     | "committed", [ ("record_hash", `String hash) ] ->
       (match Hash.of_hex hash with
        | Some record_hash -> Ok (Committed { record_hash })
        | None -> Error Invalid_hash)
     | ("intent_pending" | "aborted_intent" | "committed"), _ -> Error Unexpected_shape
     | _ -> Error (Unknown_kind kind))
  | _ -> Error Unexpected_shape
;;

let of_line state line =
  let* json =
    match Yojson.Safe.from_string line with
    | json -> Ok json
    | exception Yojson.Json_error _ -> Error Not_json
  in
  let* entry = entry_of_json json in
  let* () = Result.map_error (fun violation -> Breaks_a_rule violation) (check state entry) in
  if String.equal (to_line entry) line then Ok entry else Error Non_canonical
;;

(* ---- the file ---- *)

module Store_format = struct
  type state = State.t
  type record = entry
  type nonrec line_error = line_error
  type reject = violation

  let description = "external store"
  let thread_label = "authz-external-store"
  let genesis = State.empty
  let of_line = of_line
  let to_line = to_line
  let equal_record = entry_equal
  let advance = advance
  let check_next = check
  let describe_state = describe_state
  let line_error_to_string = line_error_to_string
  let reject_to_string = violation_to_string
end

module File = Authz_jsonl_file.Make (Store_format)

type t = File.t
type writer = File.writer

type stop = Authz_jsonl_file.stop =
  { path : string
  ; reason : string
  }

type contents = Authz_jsonl_file.contents =
  | Missing
  | Empty
  | Lines of int

type tail = Authz_jsonl_file.tail =
  | Complete
  | Cut of
      { kept_bytes : int
      ; discarded_bytes : int
      }

type recovered = Authz_jsonl_file.recovered =
  { contents : contents
  ; tail : tail
  }

type 'reason open_error = 'reason File.open_error =
  | Locked of { path : string }
  | Unreadable of
      { path : string
      ; detail : string
      }
  | Line_rejected of
      { path : string
      ; line_number : int
      ; error : line_error
      }
  | Fold_refused of
      { path : string
      ; line_number : int
      ; reason : 'reason
      }

type append_error = File.append_error =
  | Writer_expired
  | Stopped of stop
  | Rejected of
      { index : int
      ; reject : violation
      }
  | Would_not_read_back of
      { index : int
      ; error : line_error
      }
  | Read_back_changed of { index : int }
  | Write_locked of { path : string }
  | Diverged of { path : string }
  | Write_failed of
      { path : string
      ; detail : string
      }

let stopped = File.stopped
let open_error_to_string = File.open_error_to_string
let open_at_start = File.open_at_start
let with_writer = File.with_writer
let append_error_to_string = File.append_error_to_string
let append = File.append
