(** Chronicle_index — index structure for navigating chronicle epochs.
    @since Project Chronicle Phase 1 *)

type epoch_summary =
  { id : string
  ; label : string
  ; start_date : string
  ; end_date : string
  ; status : Chronicle_types.epoch_status
  ; file_path : string
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

let local_sight (idx : index) ~(max_neighbors:int) ~(current_epoch_id:string) : epoch_summary list =
  (* Naive chronological nearest neighbors for Local Sight *)
  let sorted = List.sort (fun a b -> String.compare b.start_date a.start_date) idx.epochs in
  let rec filter_nearest acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ when List.length acc >= max_neighbors -> List.rev acc
    | e :: rest -> 
        if String.equal e.id current_epoch_id then filter_nearest acc rest
        else filter_nearest (e :: acc) rest
  in
  filter_nearest [] sorted
