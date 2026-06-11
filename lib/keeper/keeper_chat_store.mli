(** Keeper_chat_store — JSONL-based persistence for keeper direct
    messages.

    Each keeper owns an append-only file at
    [<base_dir>/.masc/keeper_chat/<sanitized-name>.jsonl]. Lines are
    JSON objects of the form
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines persisted between a turn's user and assistant lines
    additionally carry [tool_call_id] / [tool_call_name]; every line of
    a turn may carry the originating connector in [source]
    (e.g. "dashboard", "discord", "slack", "agent"). Connector rows may
    also carry [conversation_id] / [external_message_id], opaque route
    coordinates used by dashboards to group platform channels/threads
    without giving this store platform-specific knowledge.

    @since 2.145.0 *)

(** {1 Types} *)

type attachment = {
  id : string;
  att_type : string;
  name : string;
  size : int;
  mime_type : string;
  data : string;
}

(** One executed tool call within a turn. [args] holds the accumulated
    argument JSON; empty arguments are persisted as ["{}"]. *)
type tool_call = {
  call_id : string;
  call_name : string;
  args : string;
}

(** Authority class of the human (or agent) whose message opened a
    turn. Derived structurally from the arrival route, never from
    message content: the authenticated dashboard route is [Owner];
    anything carrying connector context is [External]. Persisted as
    ["owner"] / ["external"] in [speaker_authority] (RFC-0223 §3). *)
type speaker_authority =
  | Owner
  | External

val authority_label : speaker_authority -> string
val authority_of_label : string -> speaker_authority option

(** Identity of the user-line author. [speaker_id] / [speaker_name] are
    absent when the route supplies none (the dashboard is a single
    authenticated operator and carries no per-user identity). *)
type speaker = {
  speaker_id : string option;
  speaker_name : string option;
  speaker_authority : speaker_authority;
}

type chat_message = {
  role : Keeper_chat_role.t;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_call_id : string option;
  tool_call_name : string option;
  source : string option;
  conversation_id : string option;
  external_message_id : string option;
  speaker : speaker option;
      (** Present on user lines written since RFC-0223 P1; [None] on
          older lines, tool/assistant lines, and lines whose persisted
          [speaker_authority] label fails to parse (reported as a
          persistence read drop, row otherwise kept). *)
}

(** {1 I/O} *)

(** [append_turn ~base_dir ~keeper_name ~user_content ~user_attachments
    ?tool_calls ?source ?conversation_id ?external_message_id ?speaker
    ~assistant_content ()] appends one
    completed turn as consecutive lines — user, one line per tool call,
    assistant — sharing a single timestamp, in one write. [speaker]
    identifies the user-line author and is written on the user line
    only. [conversation_id] identifies the external conversation/thread
    coordinate and is written on all lines of the turn; [external_message_id]
    belongs to the inbound user line only. Failures are logged but never raised except for
    {!Eio.Cancel.Cancelled}. *)
val append_turn :
  base_dir:string ->
  keeper_name:string ->
  user_content:string ->
  user_attachments:attachment list ->
  ?tool_calls:tool_call list ->
  ?source:string ->
  ?conversation_id:string ->
  ?external_message_id:string ->
  ?speaker:speaker ->
  assistant_content:string ->
  unit ->
  unit

(** [append_assistant_message ~base_dir ~keeper_name ~content ?source
    ?conversation_id ()]
    
    Appends one assistant message line. Timestamp is taken from the
    earliest [utcnow ()] used by the enclosing write batch, so every
    line in the batch shares a timestamp. *)
val append_assistant_message :
  base_dir:string -> keeper_name:string -> content:string ->
  ?source:string -> ?conversation_id:string -> unit -> unit

(** [append_messages] appends each entry of [messages] as a single line
    to the JSONL file. Every entry gets its own [utcnow ()] timestamp. *)
val append_messages : base_dir:string -> keeper_name:string -> chat_message list -> unit

(** [load ~base_dir ~keeper_name ~role_filter ()] returns all persisted
    messages for the keeper, newest first. Use [~role_filter] to restrict
    to specific roles. *)
val load :
  base_dir:string -> keeper_name:string -> ?role_filter:Keeper_chat_role.RoleSet.t -> unit ->
  chat_message list

(** [load_page ~base_dir ~keeper_name ~page_size ~page ~role_filter ()]
    returns a page of messages for paginated chat UIs. [page] is 1-indexed. *)
val load_page :
  base_dir:string -> keeper_name:string -> page_size:int -> page:int ->
  ?role_filter:Keeper_chat_role.RoleSet.t -> unit ->
  Keeper_chat_types.page

(** [parse_line line] deserialises a single JSONL line. Raises
    [Failure] on malformed input. *)
val parse_line : string -> chat_message

(** [encode_line ~role ~content ~ts ()] serialises a single line to
    JSONL. *)
val encode_line :
  role:Keeper_chat_role.t -> content:string -> ts:float ->
  ?attachments:attachment list -> ?tool_call_id:string -> ?tool_call_name:string ->
  ?source:string -> ?conversation_id:string -> ?external_message_id:string -> ?speaker:speaker ->
  unit -> string

(** [encode_line_json] produces the JSON value without writing. *)
val encode_line_json :
  role:Keeper_chat_role.t -> content:string -> ts:float ->
  ?attachments:attachment list -> ?tool_call_id:string -> ?tool_call_name:string ->
  ?source:string -> ?conversation_id:string -> ?external_message_id:string -> ?speaker:speaker ->
  unit -> Yojson.Safe.t

(** {1 Serialisation} *)

(** JSON array of messages. Entries without a timestamp omit the
    [ts] field; [tool_call_id] / [tool_call_name] / [source] /
    [conversation_id] / [external_message_id] /
    [speaker_id] / [speaker_name] / [speaker_authority] appear only
    when present. *)
val to_json_array : chat_message list -> Yojson.Safe.t