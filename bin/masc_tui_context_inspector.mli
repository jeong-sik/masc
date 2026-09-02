(** Read-only projection of the last provider input retained at the
    pre-dispatch serialization boundary.

    The turn record owns exact component byte counts and provider usage. The
    provider-input snapshot owns content-addressed copies of the final system
    prompt, projected messages, and effective tool schemas for that same
    [turn_ref], plus the prepared request byte count and digest. This proves
    what was serialized, not that transport began or the provider accepted
    it. The two readings remain separate so one failed observation cannot
    erase the other. *)

type exact_input_kind =
  | System_prompt
  | Message of { role : string }
  | Tool_schema of { name : string }

type exact_input_item =
  { kind : exact_input_kind
  ; bytes : int
  ; sha256 : string
  ; text : string
  }

type provider_input =
  { trace_id : string
  ; absolute_turn : int
  ; turn_ref : Ids.Turn_ref.t
  ; runtime_profile : string
  ; captured_at : float
  ; wire : Llm_provider.Request_wire_observer.observation
  ; items : exact_input_item list
  }

type attributed_turn =
  { record : Turn_record.t
  ; components : Turn_record.input_component list
        (** Carried out of the record rather than left behind its [option] so
            a reader of this type cannot reach a state where an attributed
            turn has no attribution. *)
  ; turns_behind_latest : int
        (** Absolute-turn distance from {!selection.latest}. [0] means the
            newest row returned is itself attributed. *)
  }

type recent_turn =
  { turn : int
        (** Absolute-turn number, as [Turn_record.absolute_turn]. *)
  ; ts : float
  ; input_tokens : int option
        (** What the provider counted as this request's input. [None] when
            the provider reported a conversation-cumulative figure instead,
            which is a number about the whole conversation and not a fact
            about this turn. *)
  ; cache_read : int option
  ; output_tokens : int option
  ; scope : Runtime_usage_scope.t
  }

(** What one turn-records page yields.

    Two readings rather than one, because a keeper can keep turning while its
    exact input composition stops being recorded. Returning only the newest
    attributed row made the pane show a turn the keeper had already moved
    past without saying so, and returning nothing when the page held no
    attributed row threw away the token, usage, wire and window readings the
    newest row did carry. [latest] is always the newest row on the page;
    [attributed] is the newest row that also has an exact composition, when
    the page holds one. [recent] is every row on the page, newest first,
    with the figures a per-turn reading wants; the page is what the caller
    asked the server for, not a curated window. *)
type selection =
  { latest : Turn_record.t
  ; attributed : attributed_turn option
  ; recent : recent_turn list
  }

type reading =
  { turn : (selection, string) result
  ; provider_input : (provider_input, string) result
  }

type tab =
  | Composition
  | Exact_input
  | Input_map

type input_source =
  | Turn_prompt_assembly
  | Effective_tool_surface
  | Provider_message_list

type input_evidence =
  | Verified_exact_text
  | Serialized_turn_snapshot
  | Producer_digest_only
  | Byte_count_only

type input_map_row =
  { component : Turn_record.input_component_id
  ; bytes : int
  ; source : input_source
  ; evidence : input_evidence
  ; digest : string option
  ; exact_text : string option
  }

val decode_turn_records : Yojson.Safe.t -> (selection, string) result
(** Strictly decode every returned row and report both the newest row and the
    newest row carrying an exact input-component observation. A malformed row
    fails the reading; it is never dropped to make the input look smaller.

    An empty page is an error, but a page whose rows are all unattributed is
    not: that is a fact about the keeper worth showing rather than an absent
    reading. *)

val decode_provider_input :
  expected_keeper:string ->
  expected_turn_ref:Ids.Turn_ref.t ->
  Yojson.Safe.t ->
  (provider_input, string) result

val exact_input_category : exact_input_kind -> string
(** The group an item is counted under on the input tab. A tool schema is
    grouped with the other schemas rather than named after its own tool, so
    the summary can say what the schemas cost together. *)

val input_component_label : Turn_record.input_component_id -> string
val exact_input_label : exact_input_kind -> string
val input_source_label : input_source -> string
val input_evidence_label : input_evidence -> string
val input_evidence_badge_cells : input_evidence -> int
(** Display cells occupied by ["[ LABEL ]"]. Evidence labels are ASCII, so
    this is also the byte width; renderers use it before allocating the
    component-name column. *)

val input_map_rows :
  Turn_record.t ->
  provider_input option ->
  input_map_row list
(** The composition categories and exact input are joined only when both name
    the same [turn_ref]. Exact item text remains available in the input tab;
    categories that cannot be isolated without reinterpreting message content
    remain explicitly non-verified, distinguishing a same-turn pre-dispatch
    serialization from producer-digest-only and byte-count-only evidence.
    [digest] is producer-owned prompt-block evidence when the component is a
    prompt block; it does not authorize an item-level join by itself. *)
val exact_input_items : provider_input -> exact_input_item list
val format_bytes : int -> string
val format_tokens : int -> string
