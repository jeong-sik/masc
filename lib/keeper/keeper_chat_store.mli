(** Keeper_chat_store — JSONL-based persistence for keeper direct
    messages.

    Each keeper owns an append-only file at
    [<base_dir>/.masc/keeper_chat/<sanitized-name>.jsonl]. Lines are
    JSON objects of the form
    {v {"role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines persisted between a turn's user and assistant lines
    additionally carry [tool_call_id] / [tool_call_name]; every line of
    a turn may carry the originating connector in [source]
    (e.g. "dashboard", "discord", "slack", "agent").

    @since 2.145.0 *)

(** {1 Types} *)

(** First-class role for chat messages. Corresponds to the JSON [role]
    field: "user", "assistant", or "tool" (tool results). *)
type role =
  | User
  | Assistant
  | Tool

val role_to_string : role -> string
val role_of_string : string -> role option

(** A filter over {!role} used to scope loaded pages. [AllRoles] returns
    every message; [Roles rs] returns only messages whose role is in [rs]. *)
type role_filter =
  | AllRoles
  | Roles of role list

val role_filter_matches : role_filter -> string -> bool

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
  role : string;
  content : string;
  ts : float option;
  attachments : attachment list option;
  tool_call_id : string option;
  tool_call_name : string option;
  source : string option;
  speaker : speaker option;
      (** Present on user lines written since RFC-0223 P1; [None] on
          older lines, tool/assistant lines, and lines whose persisted
          [speaker_authority] label fails to parse (reported as a
          persistence read drop, row otherwise kept). *)
}

(** {1 I/O} *)

(** [append_turn ~base_dir ~keeper_name ~user_content ~user_attachments
    ?tool_calls ?source ?speaker ~assistant_content ()] appends one
    completed turn as consecutive lines — user, one line per tool call,
    assistant — sharing a single timestamp, in one write. [speaker]
    identifies the user-line author and is written on the user line
    only. Failures are logged but never raised except for
    {!Eio.Cancel.Cancelled}. *)
val append_turn :
  base_dir:string ->
  keeper_name:string ->
  user_content:string ->
  user_attachments:attachment list ->
  ?tool_calls:tool_call list ->
  ?source:string ->
  ?speaker:speaker ->
  assistant_content:string ->
  unit ->
  unit

(** [append_assistant_message ~base_dir ~keeper_name ~content ?source ()]
    appends one keeper-initiated assistant line with no paired user
    turn (RFC-0223 P4 [keeper_surface_post]). Same failure policy as
    {!append_turn}. *)
val append_assistant_message :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?source:string ->
  unit ->
  unit

(** [append_user_message ~base_dir ~keeper_name ~content ?source
    ?speaker ()] appends one inbound user line with no paired
    assistant turn (RFC-0226). Written at delivery time by the inbound
    recorder — the Discord gateway's ambient arm and the gate dispatch
    boundary — so the line lands whether or not a turn starts or
    replies. Same failure policy as {!append_turn}. *)
val append_user_message :
  base_dir:string ->
  keeper_name:string ->
  content:string ->
  ?source:string ->
  ?speaker:speaker ->
  unit ->
  unit

(** [load ~base_dir ~keeper_name] returns the most recent messages in
    chronological order: the last 100 user/assistant messages plus the
    tool lines belonging to them (absolute bound 400 lines). Missing
    files return [[]]. Unparseable lines are skipped. *)
val load :
  base_dir:string -> keeper_name:string -> ?role_filter:role_filter -> unit -> chat_message list

type page = { messages : chat_message list; has_more : bool }

(** [load_page ~base_dir ~keeper_name ?before ()] is the paged form of
    {!load} (RFC-0228 P1): with [before] (a message [ts]) it returns
    the window of messages strictly older than that stamp; without it,
    the tail window. [has_more] reports whether rows older than the
    returned window remain — walk backward by passing the oldest
    returned [ts] as the next [before]. Bounded I/O per call:
    binary-search probes plus one window slice, never a full scan.
    Legacy rows without [ts] are unreachable through paging (the tail
    window still serves them). *)
val load_page :
  base_dir:string -> keeper_name:string -> ?before:float -> ?role_filter:role_filter -> unit -> page

(** {1 Serialisation} *)

(** JSON array of messages. Entries without a timestamp omit the
    [ts] field; [tool_call_id] / [tool_call_name] / [source] /
    [speaker_id] / [speaker_name] / [speaker_authority] appear only
    when present. *)
val to_json_array : chat_message list -> Yojson.Safe.t
