(** Keeper_context_layers — the keeper world-state user message as an ordered
    set of typed context layers.

    Each layer owns exactly one observation signal and renders to [Some text]
    when its signal is present this turn, [None] when it carries nothing. The
    render order is a single declared SSOT ({!ordered}) rather than the implicit
    order of imperative buffer writes, so reordering or adding a section is a
    typed, reviewable change instead of an edit buried in a long procedure.

    The build is a pure fold: {!assemble} concatenates, in {!ordered} order, the
    [Some] renderings produced by a caller-supplied [content_of]. [content_of]
    is written as an exhaustive match on {!layer_id} at the call site, so adding
    a layer fails to compile until the producing site renders it. *)

type layer_id =
  | Active_goals
  | Current_task
  | Approval_authority
  | Connected_surfaces
  | Namespace_state
  | Workspace_memory
  | Wiki
  | Lane_updates
  | Repository_freshness
      (** Where each playground checkout stands against its upstream default
          branch — semi-stable standing context: it moves when the keeper
          commits or upstream advances, not per cycle. *)
  | Autonomous_trigger
  | Scheduled_automation
  | Completion_authority
  | Task_cancellations
  | Pending_mentions
  | Scope_messages
  | Own_board_posts
  | Board_activity
  | Own_recent_actions
  | Recent_work
  | Fleet_messages

val ordered : layer_id list
(** The canonical render order: larger, more stable sections first so providers
    can reuse a longer shared prefix across cycles (prefix-cache ordering);
    highly volatile reactive signals stay later. Every {!layer_id} appears
    exactly once — cross-checked against {!order_index} in
    [test_keeper_context_layers]. *)

val order_index : layer_id -> int
(** Position of a layer in {!ordered} (0-based). Exhaustive over {!layer_id}, so
    a new variant forces an arm here as well as in any [content_of]. *)

type unattributed = World_frame | Host_workspace_recall | Direct_turn | Unprojected_input

(** What one span of a rendered world state came from: a typed layer, or text
    the renderer adds around the layers. *)
type source = Layer of layer_id | Unattributed of unattributed

val source_name : source -> string
(** The stable name of a source, unique across layers and unattributed text. *)

val source_of_name : string -> source option
(** Inverse of {!source_name}. An unknown name is [None]. *)

(** How a resumed official-client session that already holds a section's exact
    bytes from an earlier turn is sent that section again
    ({!Keeper_official_client_host.resume_prompt}). A new source declares its
    class in {!resend_on_resume}'s exhaustive match. *)
type resend_on_resume =
  | Sent_when_changed
      (** Standing state. The same bytes add nothing the session does not
          already hold, so they are left out and named as unchanged. *)
  | Sent_every_resume
      (** What arrived for this turn: its trigger and its inbox rows. The same
          bytes on a later turn are a new arrival, as an operator repeating a
          note is a new utterance, so they are always sent. *)
  | Sent_with_other_sections
      (** The frame that heads the sections and says the runtime assembled
          them. It goes out whenever any section does and is left out only
          when every section is. *)

val resend_on_resume : source -> resend_on_resume

(** How a section's text divides for a resume that may already hold part of
    it ({!Keeper_official_client_host.resume_prompt}). *)
type section_rows =
  | Whole_section
      (** One text: a resume holds all of it or none of it. *)
  | Head_and_rows of { head : string; rows : string list; tail : string }
      (** [head ^ String.concat "" rows ^ tail], byte for byte. The rows are
          entries the renderer adds to, one per recorded turn, so a later turn
          repeats most of them. A resume that holds some rows sends [head], the
          rows it lacks, and [tail] (#45131). *)

type prepared_content
(** Immutable text and the SHA-256 computed from those exact UTF8 bytes. *)
val prepare_content : string -> prepared_content
(** A {!Whole_section}. *)
val prepare_rows : head:string -> rows:string list -> tail:string -> prepared_content
(** [head ^ String.concat "" rows ^ tail] as {!Head_and_rows}; with no rows it is
    a {!Whole_section}. *)
type rendered
val text : rendered -> string
val unattributed : unattributed -> string -> rendered
val append_unattributed : rendered -> unattributed -> string -> rendered
val prepend_unattributed : unattributed -> string -> rendered -> rendered
val prepend_prepared_unattributed : unattributed -> prepared_content -> rendered -> rendered
val receipt_to_json : rendered -> Yojson.Safe.t
(** Renderer-issued raw UTF8 spans, not a prepared or delivered IPC claim. *)
type section = { section_source : source; section_text : string; section_rows : section_rows }

val sections : rendered -> section list
(** Every span's source, exact text and division, in render order. The texts
    concatenate to {!text} byte for byte. *)
val assemble : content_of:(layer_id -> string option) -> rendered
(** [assemble ~content_of] renders each layer in {!ordered} via [content_of]
    and concatenates the [Some] results in order; a [None] layer contributes
    nothing. The concatenation is byte-exact — each [content_of] result is
    expected to carry its own header and trailing separators. *)
val assemble_prepared : content_of:(layer_id -> prepared_content option) -> rendered
(** Same canonical fold and fresh offsets as {!assemble}, reusing each exact
    immutable content's digest. Content identities grant no delivery claim. *)
