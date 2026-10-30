(** Closed lifecycle vocabulary emitted by the Fusion run registry. A failed
    run carries the registry's typed failure fields rather than flattening
    them into a display string. *)
type fusion_run_status =
  | Fusion_running
  | Fusion_completed
  | Fusion_failed of {
      frs_failure_code : string;
      frs_error : string;
    }

val fusion_run_status_to_string : fusion_run_status -> string

(** Typed live computation stage. Panel counts are producer facts; completed
    and failed are terminal stage/status pairs rather than inferred progress. *)
type fusion_run_stage =
  | Fusion_stage_accepted
  | Fusion_stage_panel of { frs_expected : int }
  | Fusion_stage_judge of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_computed of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_recording_evidence of
      { frs_expected : int
      ; frs_answered : int
      ; frs_failed : int
      }
  | Fusion_stage_completed
  | Fusion_stage_failed

val fusion_run_stage_to_string : fusion_run_stage -> string

type fusion_run = {
  fur_run_id : string;
  fur_keeper : string;
  fur_preset : string;
  fur_topology : Fusion_types.fusion_topology;
  fur_started_at : float;
  fur_finished_at : float option;
  fur_status : fusion_run_status;
  fur_stage : fusion_run_stage;
  (** Process-local stage for running rows, or the exact terminal stage. *)
  fur_decision : string option;
  fur_summary : string option;
  (** Bounded semantic terminal preview. Both fields are present together only
      for successes written by the current producer; legacy success rows have
      neither. *)
}

type fusion_replay =
  | Fusion_not_replayed
  | Fusion_log_absent
  | Fusion_replayed of
      { malformed_lines : int; dropped_running : int; incomplete : bool }

type fusion_historical_evidence = {
  fhe_run_id : string;
  fhe_post_id : string;
  fhe_title : string;
  fhe_created_at : float;
}

type fusion_list_entry =
  | Fusion_retained_run of fusion_run
  | Fusion_historical_evidence of fusion_historical_evidence

type fusion_snapshot = {
  fus_generated_at : string;
  fus_runs : fusion_run list;
  fus_replay : fusion_replay;
  fus_historical_evidence : fusion_historical_evidence list;
}

type fusion_panel_answer = {
  fpa_model : string;
  fpa_answer : string;
  fpa_input_tokens : int;
  fpa_output_tokens : int;
}

type fusion_panel_failure = {
  fpf_model : string;
  fpf_reason_code : string;
  fpf_reason_detail : string;
}

type fusion_panel_result =
  | Fusion_panel_answered of fusion_panel_answer
  | Fusion_panel_failed of fusion_panel_failure

type fusion_judge =
  | Fusion_judge_synthesized of {
      fj_decision : string;
      fj_resolved_answer : string;
      fj_reason : string;
    }
  | Fusion_judge_failed of {
      fj_failure_code : string;
      fj_error : string;
    }

(** RFC-0284 judge-node roles, as the server's judge_role_projection writes
    them. Closed on purpose: an untaught role fails its node's decode. *)
type fusion_judge_role = Fusion_types.judge_role_kind =
  | Judge_single
  | Judge_refine
  | Judge_first
  | Judge_meta
  | Judge_stage_meta
  | Judge_final_meta

type fusion_judge_node_outcome =
  | Judge_node_synthesized of {
      fjno_decision : string;
      fjno_resolved_answer : string;
      fjno_synthesis : string;
      fjno_input_tokens : int;
      fjno_output_tokens : int;
    }
  | Judge_node_failed of {
      fjno_failure_code : string;
      fjno_error : string;
      fjno_input_tokens : int;
      fjno_output_tokens : int;
      fjno_elapsed_s : float option;
      fjno_timed_out : bool;
    }

(** One executed judge of the deliberation: role is the topology position,
    identity names the lens (a first-pass judge) or the stage. *)
type fusion_judge_node = {
  fjn_role : fusion_judge_role;
  fjn_identity : string;
  fjn_outcome : fusion_judge_node_outcome;
}

(** A tool-trace actor's phase. A judge actor carries the same closed role
    sum as a judge node; the server writes both from one projection. *)
type fusion_tool_phase =
  | Fusion_tool_panel
  | Fusion_tool_judge of fusion_judge_role

type fusion_tool_actor =
  { fta_phase : fusion_tool_phase
  ; fta_identity : string
  }

val fusion_judge_role_label : fusion_judge_role -> string
(** The label the server projects a role under, for drawing the role
    beside an actor. *)

type fusion_tool_preview =
  { ftp_text : string
  ; ftp_bytes : int
  ; ftp_truncated : bool
  }

type fusion_tool_completion =
  | Fusion_tool_succeeded of fusion_tool_preview
  | Fusion_tool_failed of
      { ftc_output : fusion_tool_preview
      ; ftc_recoverable : bool
      ; ftc_error_class : string option
      }

type fusion_tool_event =
  | Fusion_tool_called of
      { fte_actor : fusion_tool_actor
      ; fte_agent_name : string
      ; fte_tool_use_id : string
      ; fte_turn : int
      ; fte_planned_index : int
      ; fte_tool_name : string
      ; fte_input : fusion_tool_preview
      }
  | Fusion_tool_completed of
      { fte_actor : fusion_tool_actor
      ; fte_agent_name : string
      ; fte_tool_use_id : string
      ; fte_turn : int
      ; fte_planned_index : int
      ; fte_tool_name : string
      ; fte_completion : fusion_tool_completion
      }

type fusion_tool_gap =
  { ftg_actor : fusion_tool_actor
  ; ftg_reason : string
  }

type fusion_tool_trace =
  { ftt_complete : bool
  ; ftt_observed_actors : fusion_tool_actor list
  ; ftt_dropped_events : int
  ; ftt_gaps : fusion_tool_gap list
  ; ftt_events : fusion_tool_event list
  }

(** One seat's route through its candidates (the sink's [seat_routes] array):
    who was tried, who answered. A panel seat is its panelist id; a judge seat
    is its topology role and identity, read back through the same closed role
    set the tool actors use. *)
type fusion_seat =
  | Fusion_panel_seat of string
  | Fusion_judge_seat of { fs_role : fusion_judge_role; fs_identity : string }

type fusion_seat_attempt =
  { fsa_runtime : string
  ; fsa_code : string
  ; fsa_detail : string
  }

type fusion_seat_route =
  { fsr_seat : fusion_seat
  ; fsr_route : string
  ; fsr_answered_by : string option
        (** [None]: every candidate failed, or the route did not resolve. *)
  ; fsr_failed_attempts : fusion_seat_attempt list
  }

type fusion_evidence = {
  fe_post_id : string;
  fe_title : string;
  fe_question : string;
  fe_panel : fusion_panel_result list;
  fe_judge : fusion_judge;
  fe_judges : fusion_judge_node list;
  fe_tool_trace : fusion_tool_trace;
  fe_seat_routes : fusion_seat_route list option;
      (** [None] when the post's meta carries no [seat_routes] key, which is
          how a post written before seats were recorded reads; the detail
          draws no block for it. An empty list is a post that carries the key
          with no seat in it. *)
}

type fusion_evidence_status =
  | Fusion_evidence_recorded
  | Fusion_evidence_pending
  | Fusion_evidence_absent

type fusion_detail = {
  fud_generated_at : string;
  fud_run : fusion_run;
  fud_evidence_status : fusion_evidence_status;
  fud_evidence : fusion_evidence option;
}

type fusion_historical_detail = {
  fhd_reference : fusion_historical_evidence;
  fhd_author : string;
  fhd_title : string;
  fhd_body : string;
  fhd_observations : ((int * int) option * float option, string) result;
  fhd_evidence : (fusion_evidence, string) result;
}

val decode_fusion_historical_detail :
  reference:fusion_historical_evidence -> Yojson.Safe.t ->
  (fusion_historical_detail, string) result
(** Read an exact Board original independently of registry lifecycle. Source
    identity is required; a malformed evidence payload remains an explicit
    error beside the preserved original. *)

val decode_fusion_snapshot : Yojson.Safe.t -> (fusion_snapshot, string) result
(** Decode the retained registry list from
    [GET /api/v1/dashboard/fusion-runs]. The published count must equal the
    decoded row count; unknown lifecycle labels reject the reading. *)

val decode_fusion_detail : Yojson.Safe.t -> (fusion_detail, string) result
(** Decode one exact run/evidence projection. [recorded] requires a Board post
    whose typed origin is exactly [source=fusion] and whose [fusion_run_id]
    matches the registry row. [pending] and [absent] require [post:null], and
    only a running row may be pending. Panel array order is retained. *)

(** What the Fusion launch form offers, read from
    [GET /api/v1/runtime/config/fusion]: whether Fusion is enabled, the preset
    names, and the preset the tool applies when the request names none. *)
type fusion_launch_options =
  { flo_enabled : bool
  ; flo_default_preset : string
  ; flo_presets : string list
  }

val decode_fusion_launch_options :
  Yojson.Safe.t -> (fusion_launch_options, string) result

val decode_fusion_launch_receipt : Yojson.Safe.t -> (string, string) result
(** The [run_id] a 2xx answer to [POST /api/v1/keepers/<keeper>/fusion]
    carries. A refusal is a 4xx and is reported by the transport, so a 2xx
    body with [ok:false] is an unknown shape, not a refusal. *)
