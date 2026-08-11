(** Durable projection of one autonomous continuation response.

    The producer obligation is persisted before any surface effect. External
    connector sends cross an uncertainty boundary, so an [Attempting] record
    found after restart is never blindly sent again. Dashboard transcript
    projection is different: its append-once key makes replay safe. *)

type connector_request =
  | Discord of
      { channel_id : string
      ; content : string
      ; reply_to_message_id : string option
      }
  | Slack of
      { channel_id : string
      ; content : string
      ; reply_to_message_id : string option
      }

type connector_outcome =
  | Sent of { message_id : string }
  | Rejected of { detail : string }
  | Indeterminate of { detail : string }

type transcript_outcome =
  | Appended of { row_id : string }
  | Already_present of { row_id : string }

type adapter =
  { now : unit -> float
  ; append_transcript :
      config:Workspace.config ->
      Keeper_continuation_delivery_intent.t ->
      (transcript_outcome, string) result
  ; send_connector : connector_request -> connector_outcome
  }

type outcome =
  | Delivered of Keeper_continuation_delivery_intent.t
  | Failed of Keeper_continuation_delivery_intent.t
  | Ambiguous of Keeper_continuation_delivery_intent.t

type error =
  | Store_failed of Keeper_continuation_delivery_store.error
  | Intent_transition_failed of Keeper_continuation_delivery_intent.error
  | Transcript_failed of string
  | Invalid_delivery_identity of string

val error_to_string : error -> string

val publish :
  config:Workspace.config ->
  Keeper_continuation_delivery_intent.t ->
  (outcome, error) result
(** Production adapter over the dashboard transcript and the Discord/Slack
    connector clients. A successful return always carries a persisted terminal
    intent. Callers must commit the Pending intent before invoking this
    function. After that outbox boundary, [Error] defers connector settlement
    but never authorizes response regeneration or retention of the originating
    source at the active queue head. *)

module For_testing : sig
  val publish_with_adapter :
    adapter:adapter ->
    config:Workspace.config ->
    Keeper_continuation_delivery_intent.t ->
    (outcome, error) result
end
