(** Read-only owner projection for a retained Skill activation trace.

    The result combines exact current metadata, typed trace history, and the
    producer-owned runtime-manifest filename. It never invents an owner when
    retained Keepers disagree. *)

type source =
  | Current_meta
  | Trace_history
  | Runtime_manifest

type claim =
  { keeper_name : Keeper_id.Keeper_name.t
  ; source : source
  }

type owner =
  | Known of claim
  | Not_claimed_in_retained_catalog
  | Conflicting of claim list
  | Incomplete of claim list
  | Catalog_unavailable

type manifest_error =
  | Manifest_read_failed of Fs_compat.owned_regular_file_read_error
  | Manifest_empty
  | Manifest_invalid_json of
      { line_number : int
      ; detail : string
      }
  | Manifest_invalid_row of
      { line_number : int
      ; detail : string
      }
  | Manifest_identity_mismatch of
      { line_number : int
      ; observed_keeper : string
      ; observed_trace : string
      }

type gap =
  | Keeper_catalog_unavailable of string
  | Keeper_catalog_changed_during_resolution
  | Invalid_persisted_keeper_name of string
  | Keeper_meta_name_mismatch of
      { catalog_name : Keeper_id.Keeper_name.t
      ; metadata_name : string
      }
  | Keeper_meta_unavailable of
      { keeper_name : Keeper_id.Keeper_name.t
      ; detail : string
      }
  | Runtime_manifest_entry_unreadable of
      { keeper_name : Keeper_id.Keeper_name.t
      ; cause : manifest_error
      }

type t =
  { owner : owner
  ; gaps : gap list
  }

val resolve : Workspace.config -> Keeper_id.Trace_id.t -> t

module For_testing : sig
  val resolve :
    after_claims:(unit -> unit) ->
    Workspace.config ->
    Keeper_id.Trace_id.t ->
    t
end
