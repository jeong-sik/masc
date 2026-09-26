(** Runtime_muse_msp — the Muse Session Protocol (MSP) v1 wire codec.

    [muse serve] speaks MSP: newline-delimited JSON-RPC 2.0 over stdio, one
    object per line. This module is the pure boundary of that protocol. It
    builds the frames MASC writes and decodes the frames the server writes
    into closed types. It spawns nothing and holds no state; the process
    client drives it.

    The source of truth is the stable MSP schema that
    github.com/meta-models/muse-code-sdk publishes ([schema/msp/msp.d.ts] at
    a7c10c5, host 1.3.0). Every enum the schema marks open ([TurnTerminal],
    [TurnErrorKind], [ItemKind], [ItemStatus], [ApprovalDecision], and the
    approval subject kind) decodes to a closed variant. The variant has one
    [Unrecognized_*] arm that keeps the wire value, so a later host's value
    is reported as itself rather than taken for a value MASC knows. The
    enums the schema closes ([ApprovalMode], [ReasoningEffort]) have no such
    arm. *)

type error =
  { stage : string
  ; detail : string
  }

val error_to_string : error -> string

(** {1 Frames} *)

(** A JSON-RPC id. MASC numbers its own requests; the server's requests to
    MASC carry integers in the published transcripts, but JSON-RPC allows a
    string, and the published transcripts also answer a string id. *)
type request_id =
  | Int_id of int
  | String_id of string

val request_id_to_json : request_id -> Yojson.Safe.t

type wire_message =
  | Response of
      { id : request_id
      ; result : Yojson.Safe.t
      }
  | Response_error of
      { id : request_id option
        (** [None] for JSON-RPC's [null] id: an error the server could not
            tie to a request, such as a line it could not parse. *)
      ; code : int
      ; message : string
      ; data : Yojson.Safe.t option
      }
  | Notification of
      { method_ : string
      ; params : Yojson.Safe.t
      }
  | Server_request of
      { id : request_id
      ; method_ : string
      ; params : Yojson.Safe.t
      }

val parse_wire_line : string -> (wire_message, error) result
(** Decode one stdout line. A line that repeats a key anywhere is refused:
    it parses, but it does not say one thing. A notification with no
    [params] reads as an empty object; MSP's own [initialized] has none. *)

(** {1 Client to server} *)

type client_info =
  { name : string  (** [[a-z0-9_]+]; the host refuses anything else. *)
  ; version : string
  }

(** A grantable connection capability. MSP leaves this set open, so a name
    the host grants that MASC does not know is kept verbatim. *)
type capability =
  | Session_mcp
      (** Required before [session/start] or [session/resume] may carry
          [config.mcpServers]; without the grant the host fails the whole
          command with [capabilityRequired] (-32010). *)
  | User_shell
  | Session_list_stream
  | Unrecognized_capability of string

val initialize_request
  :  id:int
  -> client_info
  -> requested_capabilities:capability list
  -> user_input_dialogs:bool
  -> Yojson.Safe.t
(** [user_input_dialogs:false] tells the host this client cannot answer a
    [userInput/request], so the host does not send one. Absent on the wire
    means capable, so [true] leaves the member off. *)

val initialized_notification : Yojson.Safe.t
(** Sent once after the [initialize] response. *)

(** The approval enforcement modes. MSP closes this set: a client selects a
    mode the host already defines and never describes one. *)
type approval_mode =
  | Allow_all
  | Prompt_unmatched
  | On_request
  | Deny_unmatched

val approval_mode_to_string : approval_mode -> string

(** The eight reasoning tiers. MSP closes this set. [Effort_none] is
    refused by the [meta] provider (the CLI exits 2 on it), so a catalog row
    that names it fails at the host. MASC does not replace it with another
    tier. *)
type reasoning_effort =
  | Effort_none
  | Effort_minimal
  | Effort_low
  | Effort_medium
  | Effort_high
  | Effort_xhigh
  | Effort_max
  | Effort_ultra

val reasoning_effort_to_string : reasoning_effort -> string
val reasoning_effort_of_string : string -> reasoning_effort option

(** A native MCP server added to one session only
    ([SessionConfig.mcpServers]). The schema closes the transport union.
    MASC offers its tools through a loopback HTTP bridge, so only the
    streamable-HTTP arm is built here. *)
type mcp_server =
  | Streamable_http of
      { url : string
      ; headers : (string * string) list
      ; required : bool
        (** [true] makes a server that fails to start fail the session.
            [false] lets the session run without it. *)
      }

type session_config = { mcp_servers : (string * mcp_server) list }

val session_start_request
  :  id:int
  -> command_id:string
  -> workspace_root:string
  -> model_id:string option
  -> approval_mode:approval_mode option
  -> config:session_config
  -> Yojson.Safe.t
(** [workspace_root] must be absolute; the host folds it into the session's
    first record. [None] for [model_id] or [approval_mode] leaves the host
    default in place. *)

val session_resume_request
  :  id:int
  -> command_id:string
  -> session_id:string
  -> config:session_config
  -> Yojson.Safe.t
(** Loads an existing session without replaying its history into the
    result ([excludeItems]). The host already holds that history, and MASC
    does not read it back. *)

type input_part =
  | Text of string
  | Image of
      { media_type : string
      ; base64_data : string  (** Raw base64, no data-URL prefix. *)
      }

val session_set_approval_mode_request
  :  id:int
  -> command_id:string
  -> session_id:string
  -> approval_mode
  -> Yojson.Safe.t
(** [session/resume] carries no approval mode: a resumed session keeps the
    one it last had. This command selects the mode for the next action. *)

val turn_start_request
  :  id:int
  -> session_id:string
  -> command_id:string
  -> input:input_part list
  -> reasoning_effort:reasoning_effort option
  -> Yojson.Safe.t
(** [input] must be non-empty; the host refuses an empty list as invalid
    params. The fresh turn's id is [command_id] (MSP SS3.1.4). *)

val turn_interrupt_request
  :  id:int
  -> session_id:string
  -> command_id:string
  -> turn_id:string
  -> Yojson.Safe.t

val usage_read_request : id:int -> Yojson.Safe.t

val server_request_error : request_id -> code:int -> message:string -> Yojson.Safe.t
(** A JSON-RPC error answer to a server request this client does not serve. *)

val method_not_found : int
(** JSON-RPC's [-32601]. *)

val server_request_ack : request_id -> Yojson.Safe.t
(** The empty result that acknowledges a server request. It only admits the
    request. The decision goes through a separate command, for an approval
    that is [approval_decide_request]. *)

(** {1 Server to client} *)

type initialize_result =
  { server_version : string
  ; user_agent : string
  ; muse_home : string
  ; schema_fingerprint : string
  ; granted_capabilities : capability list
    (** Fixed for the connection's lifetime. *)
  }

val parse_initialize_result : Yojson.Safe.t -> (initialize_result, error) result
(** Refuses a [schema.version] other than 1: this codec reads MSP v1 only,
    and the SDK is a pre-1.0 developer preview, so a host that moved on is
    named at the handshake rather than by a missing field mid-turn. *)

val corpus_schema_fingerprint : string
(** The stable-surface fingerprint of the conformance corpus this codec is
    tested against (muse-code-sdk a7c10c5). A host that reports another one
    still speaks v1, but its frames were not the ones proven here; the
    process client reports the difference rather than refusing it. *)

type session =
  { session_id : string
  ; model_id : string option
  ; workspace_root : string option
  }

val parse_session_result : stage:string -> Yojson.Safe.t -> (session, error) result
(** The [session] member of a [session/start] or [session/resume] result. *)

type turn_disposition =
  | Started
  | Queued
  | Steered
  | Unrecognized_disposition of string

type turn_start_ack =
  { turn_id : string
  ; disposition : turn_disposition
  }

val parse_turn_start_result : Yojson.Safe.t -> (turn_start_ack, error) result

(** A turn's summed token counters, verbatim ([TokenUsage]). The schema
    warns that [cached_tokens] sits inside or beside [input_tokens]
    depending on the provider, so nothing here adds them. *)
type token_usage =
  { input_tokens : int
  ; output_tokens : int
  ; cached_tokens : int
  ; reasoning_tokens : int
  }

type turn_error_kind =
  | Step_limit
  | Config_error
  | Projection_error
  | Log_error
  | Workflow_launch_error
  | Environment_error
  | Model_error
  | Launch_error
  | Auth_required
  | Unrecognized_error_kind of string

val turn_error_kind_to_string : turn_error_kind -> string
(** The wire value, the one an [Unrecognized_error_kind] keeps included. *)

type turn_error =
  { kind : turn_error_kind
  ; message : string
  ; retryable : bool  (** The host's judgment that the same input may succeed. *)
  }

type terminal =
  | Terminal_completed
  | Terminal_failed of turn_error
  | Terminal_cancelled
  | Unrecognized_terminal of string

type item_kind =
  | User_message
  | Agent_message
  | Reasoning
  | Tool_call
  | User_shell
  | Subagent
  | Workflow
  | Reminder_child
  | Compaction
  | Unrecognized_item_kind of string

type item_status =
  | In_progress
  | Item_completed_status
  | Item_failed
  | Item_cancelled
  | Item_rejected
  | Item_timed_out
  | Unrecognized_item_status of string

(** One transcript item at one revision. Only the members MASC projects are
    decoded; the schema keeps the rest open. [text] is the accumulated reply
    on an [Agent_message]. [tool], [call_id], [args] (the model's argument
    JSON, verbatim) and [visible_output] belong to a [Tool_call]. *)
type item =
  { item_id : string
  ; kind : item_kind
  ; status : item_status
  ; revision : int
  ; turn_id : string option
  ; text : string option
  ; tool : string option
  ; call_id : string option
  ; args : string option
  ; visible_output : string option
  }

(** The field an [item/delta] appends to. Absent on the wire means [text]. *)
type delta_field =
  | Delta_text
  | Delta_output
  | Delta_summary of int
  | Unrecognized_delta_field of string

type usage_window =
  { used_percent : int  (** Verbatim; above 100 when over quota. *)
  ; resets_at_ms : int
  ; window_duration_mins : int
  }

type usage_weekly =
  { weekly_used_percent : int
  ; weekly_resets_at_ms : int
  }

(** The last subscription usage the host observed ([SubscriptionUsage]).
    It is point-in-time: [observed_at_ms] is when the host received it. *)
type subscription_usage =
  { observed_at_ms : int
  ; tier : string
  ; window : usage_window
  ; weekly : usage_weekly
  }

type notification =
  | Turn_started of
      { session_id : string
      ; turn_id : string
      }
  | Turn_completed of
      { session_id : string
      ; turn_id : string
      ; terminal : terminal
      ; usage : token_usage option
      ; reason : string option  (** Display text only; never branched on. *)
      }
  | Item_started of
      { session_id : string
      ; item : item
      }
  | Item_updated of
      { session_id : string
      ; item : item
      }
  | Item_completed of
      { session_id : string
      ; item : item
      }
  | Item_delta of
      { session_id : string
      ; item_id : string
      ; field : delta_field
      ; delta : string
      }
  | Usage_changed of subscription_usage
  | Unhandled_notification of { method_ : string }
      (** A method this codec does not project: [session/started] and the
          other session projections, approval view events, [view/gap], and
          methods a later host adds. The schema requires clients to tolerate
          these. The method is kept so an observer can report it. *)

val parse_notification : method_:string -> Yojson.Safe.t -> (notification, error) result

type approval_decision =
  | Approved
  | Approved_for_session
  | Approved_policy_amendment
  | Denied
  | Denied_policy_amendment
  | Timed_out
  | Abort
  | Unrecognized_decision of string

type approval_subject_kind =
  | Subject_shell
  | Subject_file_access
  | Subject_network
  | Subject_unix_socket
  | Subject_process
  | Subject_tool
  | Unrecognized_subject of string

type approval_choice =
  { choice_id : string
  ; decision : approval_decision
  }

type approval_requirement =
  { requirement_approval_id : string
  ; source_index : int
  }

type approval_request =
  { session_id : string
  ; approval_id : string
  ; requirement : approval_requirement
  ; turn_id : string
  ; tool_name : string
  ; subject_kind : approval_subject_kind
  ; choices : approval_choice list
  }

type server_request =
  | Approval_request of approval_request
  | User_input_request of
      { session_id : string
      ; user_input_id : string
      ; turn_id : string
      }
  | Unhandled_server_request of { method_ : string }

val parse_server_request : method_:string -> Yojson.Safe.t -> (server_request, error) result

val approval_decide_request
  :  id:int
  -> command_id:string
  -> approval_request
  -> approval_choice
  -> Yojson.Safe.t
(** Decides [approval_request] with one of its own [choices]; taking the
    choice rather than its id keeps a choice the host never offered out of
    reach. The request's
    [requirement] is sent back unchanged: MSP uses it to guard against a
    decision landing on a later stage of the approval. *)

(** Who closed an approval ([ApprovalResolvedBy]). Open on the wire. *)
type approval_resolver =
  | Resolved_by_user
  | Resolved_by_policy
  | Resolved_by_llm_judge
  | Unrecognized_resolver of string

(** The terminal that won an approval ([ApprovalResolutionSummary]). *)
type approval_resolution =
  { decision : approval_decision
  ; resolved_by : approval_resolver
  }

(** [error.data.kind] ([ErrorKind], SS1.6), less [approvalAlreadyResolved],
    which {!rpc_error_data} carries as its own case. Open on the wire. *)
type rpc_error_kind =
  | Rpc_parse_error
  | Rpc_invalid_request
  | Rpc_not_initialized
  | Rpc_already_initialized
  | Rpc_method_not_found
  | Rpc_experimental_required
  | Rpc_invalid_params
  | Rpc_internal
  | Rpc_page_event_too_large
  | Rpc_output_result_too_large
  | Rpc_overloaded
  | Rpc_input_too_large
  | Rpc_capability_required
  | Rpc_not_found
  | Rpc_interrupted
  | Rpc_cancelled
  | Rpc_session_not_found
  | Rpc_session_in_use
  | Rpc_session_ambiguous
  | Rpc_fork_boundary_invalid
  | Rpc_session_not_loaded
  | Rpc_session_stream_mismatch
  | Rpc_command_rejected
  | Rpc_backpressured
  | Rpc_skill_not_found
  | Rpc_view_truncated
  | Rpc_output_unavailable
  | Rpc_boundary_pruned
  | Rpc_boundary_unusable
  | Rpc_no_boundary
  | Rpc_approval_not_found
  | Rpc_approval_choice_invalid
  | Rpc_approval_requirement_stale
  | Rpc_approval_reviewer_unavailable
  | Rpc_user_input_not_found
  | Rpc_user_input_already_settled
  | Rpc_user_input_answer_invalid
  | Unrecognized_rpc_error_kind of string

type rpc_error_data =
  | Approval_already_resolved of approval_resolution option
      (** [approvalAlreadyResolved] (-32051): something else closed the
          approval before this client's [approval/decide] landed, such as
          the host's own policy under [denyUnmatched]. The schema keeps the
          winning resolution optional. *)
  | Rpc_error_kind of rpc_error_kind

val parse_rpc_error_data : Yojson.Safe.t -> (rpc_error_data, error) result
(** Reads a JSON-RPC error's [data]. [kind] is required whenever [data] is
    present (SS1.6); the message text is never read. *)

val parse_usage_read_result : Yojson.Safe.t -> (subscription_usage option, error) result
(** [None] when the host has observed no usage yet. The schema omits the
    member in that case rather than sending an error. *)
