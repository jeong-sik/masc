type intent =
  { keeper_name : string
  ; turn_ref : Ids.Turn_ref.t
  ; content : string
  }

type append_result =
  | Appended of intent
  | Already_present

type issue_stage =
  | Load_pending
  | Persist_intent
  | Append_chat
  | Retire_intent

type issue =
  { stage : issue_stage
  ; detail : string
  }

type pending_batch =
  { intents : intent list
  ; issues : string list
  }

type io =
  { load_pending : unit -> (pending_batch, string) result
  ; persist : intent -> (unit, string) result
  ; append : intent -> (append_result, string) result
  ; retire : intent -> (unit, string) result
  ; broadcast : intent -> unit
  }

val issue_stage_to_string : issue_stage -> string
val issue_to_string : issue -> string

(** Persist the exact intent before attempting the chat append. An append
    failure leaves the intent durable for {!retry_pending}. *)
val record_and_project : io -> intent -> issue list

(** Retry all valid durable intents in exact absolute-turn order. Invalid
    entries are reported independently without blocking valid intents. Chat
    append is idempotent by [turn_ref], so a crash after append but before
    retirement cannot duplicate the row. *)
val retry_pending : io -> issue list

val production_io : base_dir:string -> keeper_name:string -> io
