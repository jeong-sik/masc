(** Strict current memory-health model and decoder for the fleet surface.
    This reads a supplied snapshot; it owns neither storage nor observation. *)
open Tui_decode_fields

let ( let* ) = Result.bind

type memory_alert_code =
  | Snapshot_read_error
  | Source_snapshot_read_error
  | Librarian_stopped
  | Librarian_failures
  | Librarian_starvation
  | Vision_ingest_errors

type memory_alert = {
  ma_code : memory_alert_code;
  ma_label : string;
  ma_message : string;
}

(* How the keeper's last durable Librarian pass ended, one constructor per
   [Keeper_librarian_queue_refresh.pass_end]. A pass that stopped on an error
   or raised carries the server's account of why; the other endings have
   none, so the detail lives on the constructor instead of beside it. *)
type memory_librarian_pass_end =
  | Pass_off
  | Pass_lane_unconfigured
  | Pass_drained
  | Pass_not_committed
  | Pass_stopped of string
  | Pass_raised of string

(* Why a Librarian pass journaled a failure, one constructor per
   [Keeper_memory_os_current.librarian_failure_kind]. *)
type memory_librarian_failure_kind =
  | Failure_prompt_render
  | Failure_execution_clock_unavailable
  | Failure_exact_setup
  | Failure_exact_execution
  | Failure_domain_output_invalid
  | Failure_absorb_judgment
  | Failure_memory_snapshot_write
  | Failure_runtime_context_unavailable
  | Failure_lane_cancelled
  | Failure_unhandled_exception

(* RFC librarian-lifecycle §4.10: the atoms the Keeper's requests skip
   because the Librarian stands behind the start the provider last
   accepted. [mls_gap_end_atom] is that start; the gap ends just before it.
   [Stalled_unmeasured] is a file the gap is read from that did not read:
   neither "no gap" nor a gap. *)
type memory_librarian_stall_cause =
  | Stall_meta_unreadable
  | Stall_turn_records_unreadable
  | Stall_turn_boundary_refused
  | Stall_snapshot_unreadable
  | Stall_read_position_unreadable

type memory_librarian_stalled =
  | Stalled_gap of {
      mls_gap_start_atom : int;
      mls_gap_end_atom : int;
    }
  | Stalled_unmeasured of {
      mls_cause : memory_librarian_stall_cause;
      mls_detail : string;
    }

(* RFC librarian-lifecycle §4.9: how far behind the keeper's Librarian is
   standing, and what its last pass and its journal say. [None] in a field is
   "not measured", which the header prints as such; it is not zero. *)
type memory_librarian_health = {
  mlh_state : memory_librarian_pass_end option;
  mlh_measured_at : float option;
  mlh_unread_atom_turns : int option;
  mlh_unread_official_turns : int option;
  mlh_continuity_unread_atoms : int option;
  mlh_last_success_at : float option;
  mlh_last_failure_kind : memory_librarian_failure_kind option;
  mlh_stalled : memory_librarian_stalled option;
}

type memory_context_frontier = {
  mcf_trace_id : string;
  mcf_end_atom : int;
  mcf_boundary_line : int;
}
type memory_context_position = {
  mcpo_trace_id : string;
  mcpo_end_atom : int;
}
type memory_context_input =
  | Context_summarized of memory_context_frontier
  | Context_absorbed of memory_context_position
  | Context_without_snapshot
  | Context_not_applied

type memory_context_prepared = {
  mcp_prepared_at : float;
  mcp_runtime_id : string;
  mcp_input : memory_context_input;
  mcp_request_bytes : int;
}
type memory_context_cycle = {
  mcc_saved : memory_context_frontier option;
  mcc_saved_unreadable : bool;
  (* Where the Librarian has read to, beside where its snapshot cuts. A
     snapshot that stopped moving while the position kept going is what a
     request pays for: it starts at the cut and carries every atom since
     (#37793). The distance is [mcc_read_position - mcc_saved.mcf_end_atom]
     and is not carried as a field of its own. *)
  mcc_read_position : int option;
  mcc_read_position_unreadable : bool;
  (* Where a snapshot being rewritten from atom 0 has to reach before a
     request starts from it. [None] on a snapshot that is not being
     rewritten. *)
  mcc_rewriting_through : int option;
  mcc_prepared : memory_context_prepared option;
  mcc_synthesis : Keeper_continuity_observation.synthesis option;
}

type memory_keeper_health = {
  mkh_keeper_id : string;
  mkh_revision : int;
  mkh_updated_at : float option;
  mkh_facts : int;
  mkh_observed_facts : int;
  mkh_derived_facts : int;
  mkh_support_invalidations : int;
  mkh_snapshot_bytes : int;
  mkh_added : int;
  mkh_removed : int;
  mkh_snapshot_present : bool;
  mkh_context_cycle : memory_context_cycle;
  mkh_librarian : memory_librarian_health;
  mkh_librarian_failures : int;
  mkh_vision_ingest_errors : int;
  mkh_vision_ingest_error_reasons : (string * int) list;
  mkh_read_error : string option;
  mkh_source_revision : int;
  mkh_source_facts : int;
  mkh_source_invalidations : int;
  mkh_source_snapshot_bytes : int;
  mkh_source_snapshot_present : bool;
  mkh_source_read_error : string option;
  mkh_alerts : memory_alert list;
}

(* A keeper row this build could not read. The rest of the fleet still
   decodes: one row from a newer server must not blank the pane. [None] when
   the row's own [keeper_id] could not be read either. *)
type memory_keeper_refusal = {
  mkr_keeper_id : string option;
  mkr_reason : string;
}

type memory_health_snapshot = {
  mhs_generated_at : float;
  mhs_keepers : memory_keeper_health list;
  mhs_refused_keepers : memory_keeper_refusal list;
  mhs_total_facts : int;
  mhs_total_observed_facts : int;
  mhs_total_derived_facts : int;
  mhs_total_support_invalidations : int;
  mhs_total_snapshot_bytes : int;
  mhs_total_source_facts : int;
  mhs_total_source_invalidations : int;
  mhs_total_source_snapshot_bytes : int;
  mhs_total_librarian_failures : int;
  mhs_total_librarian_unread_turns : int option;
  mhs_total_librarian_continuity_unread_atoms : int;
  mhs_total_librarian_continuity_unmeasured : int;
  mhs_total_vision_ingest_errors : int;
  mhs_total_read_errors : int;
  mhs_total_source_read_errors : int;
  mhs_warn_alerts : int;
  mhs_error_alerts : int;
  mhs_starving_keepers : int;
}

(* Name the fields that disagree. The check is strict on purpose -- a dashboard
   payload whose shape has drifted is refused rather than read around -- but the
   refusal used to say only "unknown, duplicate, or missing fields" for a
   nine-kilobyte object, leaving the operator to diff the payload against the
   decoder by hand. The three lists that settle the verdict are the three lists
   worth printing, so the verdict is made from them instead of from a pair of
   length and set comparisons that then get thrown away.

   The wording follows the copy of this check in [Llm_provider.Types], which
   has printed all three groups since it was written: same keys, same
   brackets, so one reader learns one shape.

   Empty groups are left out rather than drawn as "[]" -- this message goes on
   a terminal row, where the surface cuts it. *)
let require_exact_object_fields context expected = function
  | `Assoc fields ->
    let actual = List.map fst fields in
    let seen = List.sort_uniq String.compare actual in
    let unknown = List.filter (fun f -> not (List.mem f expected)) seen in
    let missing =
      List.filter (fun f -> not (List.mem f seen))
        (List.sort_uniq String.compare expected)
    in
    let duplicate =
      List.filter
        (fun f -> List.length (List.filter (String.equal f) actual) > 1)
        seen
    in
    (match (unknown, missing, duplicate) with
     | [], [], [] -> Ok ()
     | _ ->
         let group label = function
           | [] -> None
           | names ->
               Some (Printf.sprintf "%s=[%s]" label (String.concat ", " names))
         in
         let groups =
           List.filter_map
             (fun part -> part)
             [ group "missing" missing
             ; group "unknown" unknown
             ; group "duplicates" duplicate
             ]
         in
         Error
           (Printf.sprintf "%s fields mismatch (%s)" context
              (String.concat ", " groups)))
  | _ -> Error (context ^ " must be an object")
;;

let memory_alert_severity = function
  | Snapshot_read_error
  | Source_snapshot_read_error
  | Librarian_stopped
  | Librarian_failures
  | Vision_ingest_errors -> `Warn
  | Librarian_starvation -> `Error

let memory_alert_code_of_wire = function
  | "snapshot_read_error" -> Some Snapshot_read_error
  | "source_snapshot_read_error" -> Some Source_snapshot_read_error
  | "librarian_stopped" -> Some Librarian_stopped
  | "librarian_failures" -> Some Librarian_failures
  | "librarian_starvation" -> Some Librarian_starvation
  | "vision_ingest_errors" -> Some Vision_ingest_errors
  | _ -> None

let memory_alert_severity_wire code =
  match memory_alert_severity code with `Warn -> "warn" | `Error -> "error"

(* The endings the server sends (RFC §4.9). A spelling this build does not
   know is refused rather than shown as an unknown word: the header's job is to
   say whether the keeper is behind, and a word it cannot place says nothing.
   [detail] travels with [stopped] and [raised] and with nothing else, so a
   pair that breaks that is refused too. *)
let decode_memory_librarian_pass_end ~state ~detail =
  match state, detail with
  | None, None -> Ok None
  | None, Some _ -> Error "librarian detail without a state"
  | Some "off", None -> Ok (Some Pass_off)
  | Some "lane_unconfigured", None -> Ok (Some Pass_lane_unconfigured)
  | Some "drained", None -> Ok (Some Pass_drained)
  | Some "not_committed", None -> Ok (Some Pass_not_committed)
  | Some "stopped", Some detail -> Ok (Some (Pass_stopped detail))
  | Some "raised", Some detail -> Ok (Some (Pass_raised detail))
  | Some (("off" | "lane_unconfigured" | "drained" | "not_committed") as state), Some _ ->
    Error ("librarian state carries a detail it has none of: " ^ state)
  | Some (("stopped" | "raised") as state), None ->
    Error ("librarian state is missing its detail: " ^ state)
  | Some state, (None | Some _) -> Error ("unsupported librarian state: " ^ state)

let decode_memory_librarian_failure_kind = function
  | None -> Ok None
  | Some "prompt_render_failure" -> Ok (Some Failure_prompt_render)
  | Some "execution_clock_unavailable" -> Ok (Some Failure_execution_clock_unavailable)
  | Some "exact_setup_failure" -> Ok (Some Failure_exact_setup)
  | Some "exact_execution_failure" -> Ok (Some Failure_exact_execution)
  | Some "domain_output_invalid" -> Ok (Some Failure_domain_output_invalid)
  | Some "absorb_judgment_failure" -> Ok (Some Failure_absorb_judgment)
  | Some "memory_snapshot_write_failure" -> Ok (Some Failure_memory_snapshot_write)
  | Some "runtime_context_unavailable" -> Ok (Some Failure_runtime_context_unavailable)
  | Some "lane_cancelled" -> Ok (Some Failure_lane_cancelled)
  | Some "unhandled_exception" -> Ok (Some Failure_unhandled_exception)
  | Some kind -> Error ("unsupported librarian failure kind: " ^ kind)

(* The server's account of why a pass stopped or crashed. The other endings
   carry none. *)
let memory_librarian_pass_end_cause = function
  | Pass_stopped cause | Pass_raised cause -> Some cause
  | Pass_off | Pass_lane_unconfigured | Pass_drained | Pass_not_committed -> None

let decode_memory_librarian_health keeper_json =
  let* json = required_member keeper_json "librarian" in
  let* () =
    require_exact_object_fields
      "memory librarian health"
      [ "state"
      ; "detail"
      ; "measured_at"
      ; "unread_atom_turns"
      ; "unread_official_turns"
      ; "continuity_unread_atoms"
      ; "last_success_at"
      ; "last_failure_kind"
      ; "stalled"
      ]
      json
  in
  let* state = required_nullable_string_field json "state" in
  let* detail = required_nullable_string_field json "detail" in
  let* mlh_state = decode_memory_librarian_pass_end ~state ~detail in
  let* mlh_measured_at = required_nullable_float_field json "measured_at" in
  let* mlh_unread_atom_turns = required_nullable_int_field json "unread_atom_turns" in
  let* mlh_unread_official_turns =
    required_nullable_int_field json "unread_official_turns"
  in
  (* Read from the continuity snapshot and the read position, not from the
     durable drain's measurement, so it carries no [measured_at] and is not
     weighed against one below. *)
  let* mlh_continuity_unread_atoms =
    required_nullable_int_field json "continuity_unread_atoms"
  in
  let* mlh_last_success_at = required_nullable_float_field json "last_success_at" in
  let* mlh_last_failure_kind =
    required_nullable_string_field json "last_failure_kind"
    |> Fun.flip Result.bind decode_memory_librarian_failure_kind
  in
  let* mlh_stalled =
    match member "stalled" json with
    | `Null -> Ok None
    | stalled ->
      let* kind = required_string_field stalled "kind" in
      (match kind with
       | "gap" ->
         let* () =
           require_exact_object_fields
             "librarian stalled gap" [ "kind"; "gap_start_atom"; "gap_end_atom" ] stalled
         in
         let* mls_gap_start_atom = required_int_field stalled "gap_start_atom" in
         let* mls_gap_end_atom = required_int_field stalled "gap_end_atom" in
         if mls_gap_start_atom >= 0 && mls_gap_end_atom > mls_gap_start_atom
         then Ok (Some (Stalled_gap { mls_gap_start_atom; mls_gap_end_atom }))
         else Error "librarian stalled gap must end after it starts"
       | "unmeasured" ->
         let* () =
           require_exact_object_fields
             "librarian stalled unmeasured" [ "kind"; "cause"; "detail" ] stalled
         in
         let* cause = required_string_field stalled "cause" in
         let* mls_cause =
           match cause with
           | "meta_unreadable" -> Ok Stall_meta_unreadable
           | "turn_records_unreadable" -> Ok Stall_turn_records_unreadable
           | "turn_boundary_refused" -> Ok Stall_turn_boundary_refused
           | "snapshot_unreadable" -> Ok Stall_snapshot_unreadable
           | "read_position_unreadable" -> Ok Stall_read_position_unreadable
           | other -> Error ("unknown librarian stalled cause: " ^ other)
         in
         let* mls_detail = required_string_field stalled "detail" in
         Ok (Some (Stalled_unmeasured { mls_cause; mls_detail }))
       | other -> Error ("unknown librarian stalled kind: " ^ other))
  in
  let* () =
    if List.for_all
         (fun count -> Option.fold ~none:true ~some:(fun count -> count >= 0) count)
         [ mlh_unread_atom_turns; mlh_unread_official_turns; mlh_continuity_unread_atoms ]
    then Ok ()
    else Error "librarian unread turns must be non-negative"
  in
  let* () =
    (* A count without a measurement has no time it was taken at. *)
    if Option.is_some mlh_measured_at
       || (Option.is_none mlh_unread_atom_turns
           && Option.is_none mlh_unread_official_turns
           && Option.is_none mlh_state)
    then Ok ()
    else Error "librarian measurement must carry the time it was taken"
  in
  Ok
    { mlh_state
    ; mlh_measured_at
    ; mlh_unread_atom_turns
    ; mlh_unread_official_turns
    ; mlh_continuity_unread_atoms
    ; mlh_last_success_at
    ; mlh_last_failure_kind
    ; mlh_stalled
    }

let decode_memory_alert json =
  let* () =
    require_exact_object_fields
      "memory alert"
      [ "code"; "severity"; "target"; "label"; "message" ]
      json
  in
  let* code = required_string_field json "code" in
  let* severity = required_string_field json "severity" in
  let* target = required_string_field json "target" in
  let* ma_label = required_string_field json "label" in
  let* ma_message = required_string_field json "message" in
  (match memory_alert_code_of_wire code with
   | Some ma_code
     when String.equal code target
          && String.equal severity (memory_alert_severity_wire ma_code)
          && not (String.equal ma_label "")
          && not (String.equal ma_message "") -> Ok { ma_code; ma_label; ma_message }
   | Some _ | None -> Error "memory alert has an invalid typed code contract")

let decode_memory_context_cycle keeper_json =
  let* json = required_member keeper_json "context_cycle" in
  let* () = require_exact_object_fields "context cycle"
    ["saved"; "saved_read_error"; "read_position"; "read_position_read_error";
     "rewriting_through"; "prepared"; "synthesis"] json in
  let nullable decode = function `Null -> Ok None | value -> Result.map Option.some (decode value) in
  let frontier json =
    let* () = require_exact_object_fields "context frontier" ["trace_id"; "end_atom"; "boundary_line"] json in
    let* mcf_trace_id = required_string_field json "trace_id" in
    let* mcf_end_atom = required_int_field json "end_atom" in
    let* mcf_boundary_line = required_int_field json "boundary_line" in
    if String.trim mcf_trace_id = "" || mcf_end_atom < 1 || mcf_boundary_line < 1
    then Error "invalid context frontier"
    else Ok {mcf_trace_id; mcf_end_atom; mcf_boundary_line} in
  let prepared json =
    let* () = require_exact_object_fields "prepared context"
      ["prepared_at"; "runtime_id"; "input"; "request_bytes"] json in
    let* prepared_at = required_nullable_float_field json "prepared_at" in
    let* mcp_prepared_at = match prepared_at with
      | Some time when Float.is_finite time && time >= 0. -> Ok time
      | _ -> Error "invalid prepared context time" in
    let* mcp_runtime_id = required_string_field json "runtime_id" in
    let* mcp_request_bytes = required_int_field json "request_bytes" in
    let* () = if String.trim mcp_runtime_id <> "" && mcp_request_bytes >= 0
      then Ok () else Error "invalid prepared context runtime or bytes" in
    let* input = required_member json "input" in
    let* () = require_exact_object_fields "context input" ["kind"; "frontier"] input in
    let* kind = required_string_field input "kind" in
    let* value = required_member input "frontier" in
    let position json =
      let* () = require_exact_object_fields "context position" ["trace_id"; "end_atom"] json in
      let* mcpo_trace_id = required_string_field json "trace_id" in
      let* mcpo_end_atom = required_int_field json "end_atom" in
      if String.trim mcpo_trace_id = "" || mcpo_end_atom < 1
      then Error "invalid context position"
      else Ok {mcpo_trace_id; mcpo_end_atom} in
    let* mcp_input = match kind, value with
      | "summarized", (`Assoc _ as value) -> Result.map (fun value -> Context_summarized value) (frontier value)
      | "absorbed", (`Assoc _ as value) -> Result.map (fun value -> Context_absorbed value) (position value)
      | "without_snapshot", `Null -> Ok Context_without_snapshot
      | "not_applied", `Null -> Ok Context_not_applied
      | _ -> Error "context input kind disagrees with frontier" in
    Ok {mcp_prepared_at; mcp_runtime_id; mcp_request_bytes; mcp_input} in
  let* saved = required_member json "saved" in
  let* mcc_saved = nullable frontier saved in
  let* read_error = required_nullable_string_field json "saved_read_error" in
  let* mcc_saved_unreadable = match read_error, mcc_saved with
    | None, _ -> Ok false
    | Some "snapshot_unreadable", None -> Ok true
    | _ -> Error "context saved frontier disagrees with read error" in
  let* mcc_read_position = required_nullable_int_field json "read_position" in
  let* () = match mcc_read_position with
    | Some end_atom when end_atom < 1 -> Error "invalid context read position"
    | Some _ | None -> Ok () in
  let* position_read_error = required_nullable_string_field json "read_position_read_error" in
  let* mcc_read_position_unreadable = match position_read_error, mcc_read_position with
    | None, _ -> Ok false
    | Some "progress_unreadable", None -> Ok true
    | Some _, _ -> Error "context read position disagrees with read error" in
  let* mcc_rewriting_through = required_nullable_int_field json "rewriting_through" in
  (* The writer sets this only past the cut it belongs to, on a snapshot that
     was read. A value without that snapshot, or at or behind its cut, is not
     a rewrite this reader can describe. *)
  let* () = match mcc_rewriting_through, mcc_saved with
    | None, _ -> Ok ()
    | Some through, Some saved when through > saved.mcf_end_atom -> Ok ()
    | Some _, (Some _ | None) -> Error "context rewrite target disagrees with the saved cut" in
  let* value = required_member json "prepared" in
  let* mcc_prepared = nullable prepared value in
  let* value = required_member json "synthesis" in
  let* mcc_synthesis = nullable Keeper_continuity_observation.synthesis_of_json value in
  Ok {mcc_saved; mcc_saved_unreadable; mcc_read_position; mcc_read_position_unreadable;
      mcc_rewriting_through; mcc_prepared; mcc_synthesis}

let decode_memory_keeper_health json =
  let* () =
    require_exact_object_fields
      "memory keeper health"
      [ "keeper_id"
      ; "revision"
      ; "updated_at"
      ; "facts"
      ; "observed_facts"
      ; "derived_facts"
      ; "support_invalidations"
      ; "snapshot_bytes"
      ; "added"
      ; "removed"
      ; "snapshot_present"
      ; "context_cycle"
      ; "librarian"
      ; "librarian_failures"
      ; "vision_ingest_errors"
      ; "vision_ingest_error_reasons"
      ; "read_error"
      ; "source_revision"
      ; "source_facts"
      ; "source_invalidations"
      ; "source_snapshot_bytes"
      ; "source_snapshot_present"
      ; "source_read_error"
      ; "alerts"
      ]
      json
  in
  let* mkh_keeper_id = required_string_field json "keeper_id" in
  let* mkh_updated_at = required_nullable_float_field json "updated_at" in
  let* mkh_revision = required_int_field json "revision" in
  let* mkh_facts = required_int_field json "facts" in
  let* mkh_observed_facts = required_int_field json "observed_facts" in
  let* mkh_derived_facts = required_int_field json "derived_facts" in
  let* mkh_support_invalidations =
    required_int_field json "support_invalidations"
  in
  let* () =
    if mkh_observed_facts + mkh_derived_facts = mkh_facts
    then Ok ()
    else Error "ordinary fact total disagrees with observed and derived facts"
  in
  let* mkh_snapshot_bytes = required_int_field json "snapshot_bytes" in
  let* mkh_added = required_int_field json "added" in
  let* mkh_removed = required_int_field json "removed" in
  let* mkh_snapshot_present = required_bool_field json "snapshot_present" in
  let* () =
    if Option.is_some mkh_updated_at = mkh_snapshot_present
       && Option.fold ~none:true ~some:(fun ts -> Float.is_finite ts && ts >= 0.) mkh_updated_at
    then Ok ()
    else Error "memory updated_at must describe a readable snapshot"
  in
  let* mkh_context_cycle = decode_memory_context_cycle json in
  let* mkh_librarian = decode_memory_librarian_health json in
  let* mkh_librarian_failures = required_int_field json "librarian_failures" in
  let* vision_reasons_json =
    required_list_field json "vision_ingest_error_reasons"
  in
  let decode_vision_reason json =
    let* () =
      require_exact_object_fields
        "vision ingest error reason"
        [ "reason"; "count" ]
        json
    in
    let* reason = required_string_field json "reason" in
    let* count = required_int_field json "count" in
    if not (String.equal reason "") && count > 0
    then Ok (reason, count)
    else Error "vision reason and count must be present and positive"
  in
  let* mkh_vision_ingest_error_reasons =
    decode_list "vision_ingest_error_reasons" decode_vision_reason
      vision_reasons_json
  in
  let* () =
    let reasons = List.map fst mkh_vision_ingest_error_reasons in
    if List.length reasons = List.length (List.sort_uniq String.compare reasons)
    then Ok ()
    else Error "vision ingest error reasons must be unique"
  in
  let* mkh_vision_ingest_errors = required_int_field json "vision_ingest_errors" in
  let vision_reason_total =
    List.fold_left
      (fun total (_, count) -> total + count)
      0 mkh_vision_ingest_error_reasons
  in
  let* () =
    if vision_reason_total = mkh_vision_ingest_errors
    then Ok ()
    else Error "vision ingest error total disagrees with its reasons"
  in
  let* mkh_read_error = optional_string json "read_error" in
  let* mkh_source_revision = required_int_field json "source_revision" in
  let* mkh_source_facts = required_int_field json "source_facts" in
  let* mkh_source_invalidations =
    required_int_field json "source_invalidations"
  in
  let* mkh_source_snapshot_bytes =
    required_int_field json "source_snapshot_bytes"
  in
  let* mkh_source_snapshot_present =
    required_bool_field json "source_snapshot_present"
  in
  let* mkh_source_read_error = optional_string json "source_read_error" in
  let* alerts_json = required_list_field json "alerts" in
  let* mkh_alerts = decode_list "alerts" decode_memory_alert alerts_json in
  let* () =
    if
      not (String.equal mkh_keeper_id "")
      && Option.fold ~none:true ~some:(fun value -> not (String.equal value "")) mkh_read_error
      && Option.fold
           ~none:true
           ~some:(fun value -> not (String.equal value ""))
           mkh_source_read_error
      && List.for_all
        (fun count -> count >= 0)
        [ mkh_revision
        ; mkh_facts
        ; mkh_observed_facts
        ; mkh_derived_facts
        ; mkh_support_invalidations
        ; mkh_snapshot_bytes
        ; mkh_added
        ; mkh_removed
        ; mkh_librarian_failures
        ; mkh_vision_ingest_errors
        ; mkh_source_revision
        ; mkh_source_facts
        ; mkh_source_invalidations
        ; mkh_source_snapshot_bytes
        ]
    then Ok ()
    else Error "memory keeper health counts must be non-negative"
  in
  Ok
    { mkh_keeper_id
    ; mkh_revision
    ; mkh_updated_at
    ; mkh_facts
    ; mkh_observed_facts
    ; mkh_derived_facts
    ; mkh_support_invalidations
    ; mkh_snapshot_bytes
    ; mkh_added
    ; mkh_removed
    ; mkh_snapshot_present
    ; mkh_context_cycle
    ; mkh_librarian
    ; mkh_librarian_failures
    ; mkh_vision_ingest_errors
    ; mkh_vision_ingest_error_reasons
    ; mkh_read_error
    ; mkh_source_revision
    ; mkh_source_facts
    ; mkh_source_invalidations
    ; mkh_source_snapshot_bytes
    ; mkh_source_snapshot_present
    ; mkh_source_read_error
    ; mkh_alerts
    }

let decode_memory_health_snapshot json =
  let* () =
    require_exact_object_fields
      "memory health snapshot"
      [ "schema"
      ; "generated_at"
      ; "keepers"
      ; "totals"
      ; "alert_summary"
      ]
      json
  in
  let* schema = required_string_field json "schema" in
  let* () =
    if String.equal schema "keeper.memory_os.current_health.v7"
    then Ok ()
    else Error ("unsupported memory health schema: " ^ schema)
  in
  let* mhs_generated_at = Json_util.require_float json "generated_at" in
  let* () =
    if Float.is_finite mhs_generated_at && mhs_generated_at >= 0.0
    then Ok ()
    else Error "memory health observation metadata must be non-negative"
  in
  let* keepers_json = required_list_field json "keepers" in
  (* Each row is decoded on its own and a row that does not decode is kept as
     a refusal, not dropped and not folded into a default: a pass ending or a
     failure kind this build does not know stays refused, but only for that
     keeper. *)
  let rows =
    List.mapi
      (fun index row ->
         match decode_memory_keeper_health row with
         | Ok keeper -> Ok keeper
         | Error reason ->
           Error
             { mkr_keeper_id =
                 (* The row is already refused with [reason]; an unreadable
                    [keeper_id] only means the refusal cannot name its keeper. *)
                 (match required_string_field row "keeper_id" with
                  | Ok keeper_id -> Some keeper_id
                  | Error _ -> None)
             ; mkr_reason = Printf.sprintf "keepers[%d]: %s" index reason
             })
      keepers_json
  in
  let mhs_keepers, mhs_refused_keepers =
    List.partition_map
      (function Ok keeper -> Either.Left keeper | Error refusal -> Either.Right refusal)
      rows
  in
  let* () =
    let keeper_ids =
      List.map (fun keeper -> keeper.mkh_keeper_id) mhs_keepers
      @ List.filter_map (fun refusal -> refusal.mkr_keeper_id) mhs_refused_keepers
    in
    if List.length keeper_ids = List.length (List.sort_uniq String.compare keeper_ids)
    then Ok ()
    else Error "memory health keeper identities must be unique"
  in
  let* totals_json = required_member json "totals" in
  let* () =
    require_exact_object_fields
      "memory health totals"
      [ "facts"
      ; "observed_facts"
      ; "derived_facts"
      ; "support_invalidations"
      ; "snapshot_bytes"
      ; "added"
      ; "removed"
      ; "source_facts"
      ; "source_invalidations"
      ; "source_snapshot_bytes"
      ; "librarian_unread_turns"
      ; "librarian_continuity_unread_atoms"
      ; "librarian_continuity_unmeasured"
      ; "librarian_failures"
      ; "vision_ingest_errors"
      ; "read_errors"
      ; "source_read_errors"
      ]
      totals_json
  in
  let* mhs_total_facts = required_int_field totals_json "facts" in
  let* mhs_total_observed_facts =
    required_int_field totals_json "observed_facts"
  in
  let* mhs_total_derived_facts =
    required_int_field totals_json "derived_facts"
  in
  let* mhs_total_support_invalidations =
    required_int_field totals_json "support_invalidations"
  in
  let* mhs_total_snapshot_bytes =
    required_int_field totals_json "snapshot_bytes"
  in
  let* mhs_total_source_facts =
    required_int_field totals_json "source_facts"
  in
  let* mhs_total_source_invalidations =
    required_int_field totals_json "source_invalidations"
  in
  let* mhs_total_source_snapshot_bytes =
    required_int_field totals_json "source_snapshot_bytes"
  in
  let* mhs_total_librarian_failures =
    required_int_field totals_json "librarian_failures"
  in
  let* mhs_total_vision_ingest_errors =
    required_int_field totals_json "vision_ingest_errors"
  in
  let* mhs_total_read_errors = required_int_field totals_json "read_errors" in
  let* mhs_total_source_read_errors =
    required_int_field totals_json "source_read_errors"
  in
  let* total_added = required_int_field totals_json "added" in
  let* total_removed = required_int_field totals_json "removed" in
  let* mhs_total_librarian_unread_turns =
    required_nullable_int_field totals_json "librarian_unread_turns"
  in
  (* Summed over the keepers this could be taken for; the second says how many
     it could not, so the first is never read as "the fleet is caught up". *)
  let* mhs_total_librarian_continuity_unread_atoms =
    required_int_field totals_json "librarian_continuity_unread_atoms"
  in
  let* mhs_total_librarian_continuity_unmeasured =
    required_int_field totals_json "librarian_continuity_unmeasured"
  in
  let* summary_json = required_member json "alert_summary" in
  let* () =
    require_exact_object_fields
      "memory health alert summary"
      [ "total_alerts"
      ; "warn_alerts"
      ; "error_alerts"
      ; "keepers_with_alerts"
      ; "snapshot_read_error_keepers"
      ; "source_snapshot_read_error_keepers"
      ; "librarian_stopped_keepers"
      ; "librarian_starving_keepers"
      ]
      summary_json
  in
  let* total_alerts = required_int_field summary_json "total_alerts" in
  let* mhs_warn_alerts = required_int_field summary_json "warn_alerts" in
  let* mhs_error_alerts = required_int_field summary_json "error_alerts" in
  let* mhs_starving_keepers =
    required_int_field summary_json "librarian_starving_keepers"
  in
  let* keepers_with_alerts =
    required_int_field summary_json "keepers_with_alerts"
  in
  let* snapshot_read_error_keepers =
    required_int_field summary_json "snapshot_read_error_keepers"
  in
  let* source_snapshot_read_error_keepers =
    required_int_field summary_json "source_snapshot_read_error_keepers"
  in
  let* librarian_stopped_keepers =
    required_int_field summary_json "librarian_stopped_keepers"
  in
  let all_totals =
    [ mhs_total_facts
    ; mhs_total_observed_facts
    ; mhs_total_derived_facts
    ; mhs_total_support_invalidations
    ; mhs_total_snapshot_bytes
    ; total_added
    ; total_removed
    ; mhs_total_source_facts
    ; mhs_total_source_invalidations
    ; mhs_total_source_snapshot_bytes
    ; mhs_total_librarian_failures
    ; mhs_total_vision_ingest_errors
    ; mhs_total_read_errors
    ; mhs_total_source_read_errors
    ; total_alerts
    ; mhs_warn_alerts
    ; mhs_error_alerts
    ; keepers_with_alerts
    ; snapshot_read_error_keepers
    ; source_snapshot_read_error_keepers
    ; librarian_stopped_keepers
    ; mhs_starving_keepers
    ]
  in
  let* () =
    if List.for_all (fun count -> count >= 0) all_totals
    then Ok ()
    else Error "memory health fleet totals must be non-negative"
  in
  (* The server's totals and alert summary count every row it sent, including
     any this build refused, so they can only be checked against the rows when
     every row decoded. With a refused row the totals are the server's and the
     refused row is drawn as refused. *)
  let every_row_read = mhs_refused_keepers = [] in
  let sum field =
    List.fold_left (fun total keeper -> total + field keeper) 0 mhs_keepers
  in
  let expected_unread = List.fold_left (fun total keeper ->
    match total, keeper.mkh_librarian.mlh_unread_atom_turns,
          keeper.mkh_librarian.mlh_unread_official_turns with
    | Some total, Some atoms, Some official -> Some (total + atoms + official)
    | _ -> None) (Some 0) mhs_keepers in
  let* () =
    if (not every_row_read) || mhs_total_librarian_unread_turns = expected_unread then Ok ()
    else Error "memory health unread total disagrees with keeper rows"
  in
  let expected_continuity_unread, expected_continuity_unmeasured =
    List.fold_left
      (fun (total, unmeasured) keeper ->
         match keeper.mkh_librarian.mlh_continuity_unread_atoms with
         | Some atoms -> total + atoms, unmeasured
         | None -> total, unmeasured + 1)
      (0, 0)
      mhs_keepers
  in
  let* () =
    if (not every_row_read)
       || (mhs_total_librarian_continuity_unread_atoms = expected_continuity_unread
           && mhs_total_librarian_continuity_unmeasured = expected_continuity_unmeasured)
    then Ok ()
    else Error "memory health continuity lag totals disagree with keeper rows"
  in
  let expected_totals =
    [ mhs_total_facts, sum (fun keeper -> keeper.mkh_facts)
    ; mhs_total_observed_facts, sum (fun keeper -> keeper.mkh_observed_facts)
    ; mhs_total_derived_facts, sum (fun keeper -> keeper.mkh_derived_facts)
    ; mhs_total_support_invalidations, sum (fun keeper -> keeper.mkh_support_invalidations)
    ; mhs_total_snapshot_bytes, sum (fun keeper -> keeper.mkh_snapshot_bytes)
    ; total_added, sum (fun keeper -> keeper.mkh_added)
    ; total_removed, sum (fun keeper -> keeper.mkh_removed)
    ; mhs_total_source_facts, sum (fun keeper -> keeper.mkh_source_facts)
    ; mhs_total_source_invalidations, sum (fun keeper -> keeper.mkh_source_invalidations)
    ; mhs_total_source_snapshot_bytes, sum (fun keeper -> keeper.mkh_source_snapshot_bytes)
    ; mhs_total_librarian_failures, sum (fun keeper -> keeper.mkh_librarian_failures)
    ; mhs_total_vision_ingest_errors, sum (fun keeper -> keeper.mkh_vision_ingest_errors)
    ; mhs_total_read_errors, sum (fun keeper -> if Option.is_some keeper.mkh_read_error then 1 else 0)
    ; mhs_total_source_read_errors,
      sum (fun keeper -> if Option.is_some keeper.mkh_source_read_error then 1 else 0)
    ]
  in
  let* () =
    if (not every_row_read)
       || List.for_all (fun (reported, actual) -> reported = actual) expected_totals
    then Ok ()
    else Error "memory health fleet totals disagree with keeper rows"
  in
  let observed_warn_alerts =
    sum (fun keeper ->
      List.length
        (List.filter
           (fun alert ->
              match memory_alert_severity alert.ma_code with
              | `Warn -> true
              | `Error -> false)
           keeper.mkh_alerts))
  in
  let observed_error_alerts =
    sum (fun keeper ->
      List.length
        (List.filter
           (fun alert ->
              match memory_alert_severity alert.ma_code with
              | `Error -> true
              | `Warn -> false)
           keeper.mkh_alerts))
  in
  let* () =
    if
      (not every_row_read)
      || total_alerts = sum (fun keeper -> List.length keeper.mkh_alerts)
      && mhs_warn_alerts = observed_warn_alerts
      && mhs_error_alerts = observed_error_alerts
      && keepers_with_alerts = sum (fun keeper -> if keeper.mkh_alerts = [] then 0 else 1)
      && snapshot_read_error_keepers = mhs_total_read_errors
      && source_snapshot_read_error_keepers = mhs_total_source_read_errors
      && librarian_stopped_keepers
         = sum (fun keeper ->
           match keeper.mkh_librarian.mlh_state with
           | Some (Pass_lane_unconfigured | Pass_not_committed | Pass_stopped _ | Pass_raised _)
             -> 1
           | Some (Pass_off | Pass_drained) | None -> 0)
      && mhs_starving_keepers
         = sum (fun keeper ->
           if keeper.mkh_librarian_failures > 0 && not keeper.mkh_snapshot_present
           then 1
           else 0)
    then Ok ()
    else Error "memory health alert summary disagrees with keeper rows"
  in
  Ok
    { mhs_generated_at
    ; mhs_keepers
    ; mhs_refused_keepers
    ; mhs_total_facts
    ; mhs_total_observed_facts
    ; mhs_total_derived_facts
    ; mhs_total_support_invalidations
    ; mhs_total_snapshot_bytes
    ; mhs_total_source_facts
    ; mhs_total_source_invalidations
    ; mhs_total_source_snapshot_bytes
    ; mhs_total_librarian_failures
    ; mhs_total_librarian_unread_turns
    ; mhs_total_librarian_continuity_unread_atoms
    ; mhs_total_librarian_continuity_unmeasured
    ; mhs_total_vision_ingest_errors
    ; mhs_total_read_errors
    ; mhs_total_source_read_errors
    ; mhs_warn_alerts
    ; mhs_error_alerts
    ; mhs_starving_keepers
    }
