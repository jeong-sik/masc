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
  ; rows : Turn_record.t list
        (** Every row on the page, newest first. [latest] is its head and
            [recent] is its projection; the list itself is what turn
            navigation steps through, so the row an operator stepped back to
            is the same row the page decoded, not a re-derived one. *)
  }

(** What the chat transcript holds for the inspected turn -- the answer
    that came back for the request this pane is reading. The parts are
    display-ready rows from the transcript reader; this pane owns only
    their placement and their cap. *)
type response_part =
  | Reply_text of string
  | Tool_steps of string list
  | Reasoning_lines of string list

type response_turn =
  { parts : response_part list
  ; outside_newest_page : bool
        (** [true] when the newest history page held no row for this turn.
            The reply exists but this fetch did not reach it -- stepping far
            enough back outruns one page, and the pane says so rather than
            showing another turn's answer. *)
  }

(** What the next Agent Core request would carry, as the server computes it
    from the turn's own values without a turn
    ([/api/v1/keepers/:name/next-request]). Live: the pair's carried front
    and the binding's marks. As last measured, with the
    turn they were read from: the fixed prompt parts and the pinned blocks. *)
type forecast_lane =
  | Lane_agent_core
  | Lane_not_applicable of string
      (** An official-client runtime: the spawned client owns its context
          and masc carries no range for it. *)

type forecast_marks =
  { high_water_tokens : int
  ; low_water_tokens : int
  }

type forecast_parts =
  { reserved_measured_on_turn : int
  ; reserved_bytes : int
        (** Tool schemas + keeper instructions, from the newest completed
            turn on the runtime. *)
  ; pinned_measured_on_turn : int
  ; pinned_measured_on_runtime : string
        (** The lane that turn ran on; a first round is recorded mostly by
            single-request turns, so it is often another lane's. *)
  ; pinned_bytes : int
        (** Every other prompt block, from the newest turn on any lane whose
            composition is a first round's. *)
  }

type forecast_carried_origin =
  | Carried_from_ledger  (** The pair's ledger, moved by every eviction since its last request. *)
  | Carried_from_turn_record of { turn : int }
      (** No ledger since the server started: the range that turn's record measured. *)
  | Carried_halved_after_refusal of { retry : int }
  | Carried_evicted_after_refusal of { retry : int }
  | Carried_turn_start_after_seed_refusal
      (** No Librarian point, and the range a seed opened was refused as too
          large: the turn's front moved to the turn boundary. *)
  | Carried_turn_start_after_librarian_refusal
      (** A Librarian point, and the range it opened -- at the point or past
          it -- was refused as too large: the turn's front moved to the turn
          boundary. *)
  | Carried_turn_start of { end_atom : int }
      (** No front to start from: this turn's own atoms, from the end of the
          last completed turn. *)
  | Carried_turn_start_unknown of { reason : string }
      (** No front, and the turn start could not be read: the newest atom
          alone. [reason] is what the boundary reader said. *)
  | Carried_librarian_snapshot of { end_atom : int; boundary_line : int }
      (** A Librarian continuity snapshot fits: its working state rides in
          place of the atoms before [end_atom]. *)
  | Carried_librarian_progress of { end_atom : int }
      (** No snapshot fits and the Librarian's read position does: the atoms
          before [end_atom] are in memory and nothing stands in for them. *)
  | Carried_past_librarian_point of
      { librarian_end_atom : int
      ; front : forecast_carried_origin
            (** One of the carried constructors above: where the start the
                provider accepted came from. *)
      }
      (** The Librarian stands at [librarian_end_atom] and the range opens at
          a later start the provider accepted; the atoms between are in
          neither the request nor memory. *)

type forecast_carried =
  { first_atom : int
  ; kept_atoms : int
  ; transmitted_bytes : int
  ; origin : forecast_carried_origin
  ; counted_tokens : int option
        (** The ledger's measured total for its last sample, a request
            without the turn context, when known. *)
  }

(** One piece of the next request in the position it travels, as the
    server lays them out: the system prompt and the tool array, then the
    messages in wire order. *)
type forecast_slot =
  | Slot_system_prompt of { bytes : int }
  | Slot_tools of { bytes : int }
  | Slot_preamble of { bytes : int }
  | Slot_history of { atoms : int; of_atoms : int; bytes : int }
      (** [atoms] carried of [of_atoms] in the checkpoint, the wake line
          on neither side. *)
  | Slot_wake_line of { bytes : int }
  | Slot_system_context of { bytes : int; blocks : (string * int) list }
      (** [blocks] in the order the assembly concatenates them. *)

(** Whether a candidate's path rests now, as the server read it. *)
type forecast_rest =
  | Rest_serving
  | Rest_resting of { release_at : float; walk_promotes_at_release : bool }

(** Where a candidate stands in the walk the next fresh cycle takes. *)
type forecast_place =
  { walks_at : int  (** 0 walks first. *)
  ; declared_at : int option
        (** The candidate's index in the lane's declaration; [None] when the
            lane does not declare it. *)
  ; rest : forecast_rest
  }

type forecast_walk =
  { lane_id : string
  ; declared : string list  (** The lane as declared, head first. *)
  }

type forecast_candidate =
  { runtime_id : string
  ; lane : forecast_lane
  ; marks : forecast_marks option
        (** As the binding declares them; [None] leaves eviction to a refusal. *)
  ; parts : (forecast_parts, string) result
        (** [Error] is the server's reason: no composition on this runtime,
            or only post-tool ones, which carry no pinned block. *)
  ; history_atoms : int
  ; carried : forecast_carried option  (** [None] when the lane is refused. *)
  ; assembly : forecast_slot list option
        (** The request in travel order; [None] whenever [carried] or
            [parts] is. *)
  ; place : forecast_place
  }

type forecast =
  { checkpoint_messages : int
  ; wake_line_bytes : int
  ; walk : (forecast_walk, string) result
        (** [Error] is the server's reason the driver would not dispatch the
            assignment at all; the candidates are then empty. *)
  ; candidates : forecast_candidate list
        (** Every candidate of the keeper's lane, in the order the next
            fresh cycle walks them. *)
  }

type reading =
  { turn : (selection, string) result
  ; provider_input : (provider_input, string) result
  ; response : (response_turn, string) result
  ; forecast : (forecast, string) result
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

val decode_forecast : Yojson.Safe.t -> (forecast, string) result
(** Strict decode of the next-request forecast; a malformed field fails the
    reading rather than reading as an absent forecast. *)

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
val input_source : Turn_record.input_component_id -> input_source
(** Which producer a component entered the turn by. *)

val exact_input_source : exact_input_kind -> input_source
(** The same question for a retained provider item, so the request tab groups
    and colours by the producer the composition tab names. *)

val input_sources : input_source list
(** The three producers in the order a turn assembles them. *)

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
