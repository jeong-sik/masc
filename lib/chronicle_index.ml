(** Chronicle_index — index structure for navigating chronicle epochs.
    @since Project Chronicle Phase 1 *)

type epoch_summary =
  { id : string
  ; label : string
  ; start_date : string
  ; end_date : string
  ; status : Chronicle_types.epoch_status
  ; file_path : string
  ; conductivity : float
  }
[@@deriving yojson, show]

type index =
  { schema_version : int
  ; repo : string
  ; last_updated : string
  ; epochs : epoch_summary list
  ; last_commit_indexed : string
  }
[@@deriving yojson, show]

let current_schema_version = 1

let empty ~repo ~now =
  { schema_version = current_schema_version
  ; repo
  ; last_updated = now
  ; epochs = []
  ; last_commit_indexed = ""
  }

let find_epoch (idx : index) epoch_id =
  List.find_opt (fun (s : epoch_summary) -> String.equal s.id epoch_id) idx.epochs

let active_epochs (idx : index) =
  List.filter (fun (s : epoch_summary) ->
    match s.status with Chronicle_types.Active -> true | _ -> false)
    idx.epochs

let add_or_replace_epoch (idx : index) (summary : epoch_summary) =
  let filtered =
    List.filter (fun (s : epoch_summary) -> not (String.equal s.id summary.id)) idx.epochs
  in
  { idx with epochs = summary :: filtered }
