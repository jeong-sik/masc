(** Bounded observation registry for active and recently completed Fusion runs. *)

type decision_preview = private string
(** A bounded display projection of a typed Fusion judge decision. It remains
    distinct from both the authoritative [Fusion_types.judge_decision] and an
    arbitrary wire string inside the registry domain. *)

val decision_preview_of_string : string -> decision_preview
val decision_preview_to_string : decision_preview -> string

type outcome =
  | Succeeded
  | Succeeded_with_summary of
      { decision : decision_preview
      ; summary : string
      }
  | Failed of
      { reason : string
      ; code : string
      }

type run_status =
  | Running
  | Completed of outcome

type progress =
  | Progress_accepted
  | Progress_panel_running of { expected : int }
  | Progress_judge_running of
      { expected : int
      ; answered : int
      ; failed : int
      }
  | Progress_computed of
      { expected : int
      ; answered : int
      ; failed : int
      }
  | Progress_recording_evidence of
      { expected : int
      ; answered : int
      ; failed : int
      }

type run =
  { run_id : string
  ; keeper : string
  ; preset : string
  ; topology : Fusion_types.fusion_topology
      (** 이 run 이 실행한 심의 위상. obligation payload 에도 있지만 그 레코드는
          배달 직후 제거되므로, 완료된 run 의 위상을 되읽을 수 있는 자리는 여기뿐이다.
          topology 를 담지 않은 예전 replay 레코드는 스킵된다(레거시 폴백 없음). *)
  ; started_at : float
  ; status : run_status
  ; progress : progress option
      (** Process-local live observation. Replay drops running workers, so an
          intermediate stage is deliberately not persisted as resumable
          state. Completed runs always carry [None]. *)
  }

type t

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> run_id:string
  -> keeper:string
  -> preset:string
  -> topology:Fusion_types.fusion_topology
  -> started_at:float
  -> unit

val mark_completed : t -> run_id:string -> outcome:outcome -> unit
(** Complete a registered run. An unknown [run_id] is logged and is not written
    to the append-only log. *)

val mark_progress : t -> run_id:string -> progress:progress -> unit
(** Update the live stage only while the exact run remains [Running]. Unknown
    and terminal ids are ignored. *)

val list_runs : t -> run list
val get : t -> run_id:string -> run option
val status_label : run_status -> string
val run_to_yojson : run -> Yojson.Safe.t
type global_install_error = Already_installed

val global : unit -> t
val install_global : t -> (unit, global_install_error) result
val storage_filename : string
val max_completed_retained : int

val cut_replay_log : execute:bool -> string -> Run_registry_core.cut_report
(** Deployment-time store cut for {!storage_filename}. See
    {!Run_registry_core.Make.cut_replay_log}. *)
