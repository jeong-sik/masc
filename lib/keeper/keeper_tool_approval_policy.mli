(** Which tool calls an operator is asked about before they run.

    Read from what the tool already declares: its group, and whether this
    particular input only reads. Nothing here matches on tool names — the
    groups are a closed type, so a group added later has to be classified here
    or the build stops. That is the point: a new family of tools must not
    inherit "runs without asking" by saying nothing. *)

(** Why a call was or was not put to an operator. Carried rather than reduced
    to a bool so a decision can be explained where it is shown or logged. *)
type verdict =
  | Ask of { because : string }
  | Run of { because : string }

val verdict_because : verdict -> string

val verdict_for :
  tool_name:string -> input:Yojson.Safe.t -> verdict
(** Decide about one call.

    A tool with no descriptor is asked about. An unknown tool is not a safe
    tool: it is one this build cannot classify, and running it unasked would
    make "no descriptor" the quietest way past the gate.

    A call whose descriptor says this input only reads runs without asking,
    whatever its group. Reading a file to answer a question is the bulk of
    what a keeper does, and an operator asked about every read would stop
    reading the questions. *)

val question_for : tool_name:string -> input:Yojson.Safe.t -> string
(** The prompt an operator sees: what the call would do, named by the one
    argument that identifies it — the same argument the chat surfaces already
    show for a tool call. *)
