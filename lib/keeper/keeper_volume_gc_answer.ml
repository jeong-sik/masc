type outcome_kind =
  | Kept
  | Reclaim_candidate
  | Reclaimed
  | Reclaim_failed

type verdict =
  { keeper_name : string
  ; work_volume : string option
  ; build_volume : string option
  ; kind : outcome_kind
  ; outcome : string
  }

type t =
  { executed : bool
  ; image_given : bool
  ; foreign_volumes : string list
  ; keepers : verdict list
  ; unlisted_keepers : string list
  }

type summary =
  { kept : int
  ; reclaim_candidates : int
  ; reclaimed : int
  ; reclaim_failed : int
  }

let ( let* ) = Result.bind

let outcome_kind_to_string = function
  | Kept -> "kept"
  | Reclaim_candidate -> "reclaim_candidate"
  | Reclaimed -> "reclaimed"
  | Reclaim_failed -> "reclaim_failed"
;;

let outcome_kind_of_string = function
  | "kept" -> Some Kept
  | "reclaim_candidate" -> Some Reclaim_candidate
  | "reclaimed" -> Some Reclaimed
  | "reclaim_failed" -> Some Reclaim_failed
  | _ -> None
;;

let kind_of_outcome : Keeper_volume_gc.keeper_outcome -> outcome_kind = function
  | Kept _ -> Kept
  | Reclaim_candidate -> Reclaim_candidate
  | Reclaimed -> Reclaimed
  | Reclaim_failed _ -> Reclaim_failed
;;

let of_report ~executed ~image_given (report : Keeper_volume_gc.report) =
  let verdict (v : Keeper_volume_gc.keeper_verdict) =
    { keeper_name = v.keeper_name
    ; work_volume = v.work_volume
    ; build_volume = v.build_volume
    ; kind = kind_of_outcome v.outcome
    ; outcome = Keeper_volume_gc.keeper_outcome_to_string v.outcome
    }
  in
  { executed
  ; image_given
  ; foreign_volumes = report.foreign_volumes
  ; keepers = List.map verdict report.keepers
  ; unlisted_keepers = report.unlisted_keepers
  }
;;

let summary t =
  List.fold_left
    (fun s v ->
       match v.kind with
       | Kept -> { s with kept = s.kept + 1 }
       | Reclaim_candidate -> { s with reclaim_candidates = s.reclaim_candidates + 1 }
       | Reclaimed -> { s with reclaimed = s.reclaimed + 1 }
       | Reclaim_failed -> { s with reclaim_failed = s.reclaim_failed + 1 })
    { kept = 0; reclaim_candidates = 0; reclaimed = 0; reclaim_failed = 0 }
    t.keepers
;;

let reclaim_candidates t =
  List.filter_map
    (fun v ->
       match v.kind with
       | Reclaim_candidate -> Some v.keeper_name
       | Kept | Reclaimed | Reclaim_failed -> None)
    t.keepers
;;

let summary_equal a b =
  Int.equal a.kept b.kept
  && Int.equal a.reclaim_candidates b.reclaim_candidates
  && Int.equal a.reclaimed b.reclaimed
  && Int.equal a.reclaim_failed b.reclaim_failed
;;

let option_volume = function
  | None -> `Null
  | Some volume_name -> `String volume_name
;;

let verdict_to_json v =
  `Assoc
    [ "keeper_name", `String v.keeper_name
    ; "work_volume", option_volume v.work_volume
    ; "build_volume", option_volume v.build_volume
    ; "outcome_kind", `String (outcome_kind_to_string v.kind)
    ; "outcome", `String v.outcome
    ]
;;

let summary_to_json s =
  `Assoc
    [ "kept", `Int s.kept
    ; "reclaim_candidates", `Int s.reclaim_candidates
    ; "reclaimed", `Int s.reclaimed
    ; "reclaim_failed", `Int s.reclaim_failed
    ]
;;

let to_json t =
  `Assoc
    [ "executed", `Bool t.executed
    ; "image_given", `Bool t.image_given
    ; "foreign_volumes", `List (List.map (fun name -> `String name) t.foreign_volumes)
    ; "keepers", `List (List.map verdict_to_json t.keepers)
    ; "unlisted_keepers", `List (List.map (fun name -> `String name) t.unlisted_keepers)
    ; "summary", summary_to_json (summary t)
    ]
;;

let answer_surface = "masc_sandbox_volume_gc answer"

let answer_fields =
  [ "executed"; "image_given"; "foreign_volumes"; "keepers"; "unlisted_keepers"; "summary" ]
;;

let verdict_fields =
  [ "keeper_name"; "work_volume"; "build_volume"; "outcome_kind"; "outcome" ]
;;

let summary_fields = [ "kept"; "reclaim_candidates"; "reclaimed"; "reclaim_failed" ]

let object_fields ~surface = function
  | `Assoc fields -> Ok fields
  | _ -> Error (surface ^ " must be an object")
;;

let field ~surface name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" surface name)
;;

let bool_field ~surface name fields =
  let* value = field ~surface name fields in
  match value with
  | `Bool b -> Ok b
  | _ -> Error (Printf.sprintf "%s.%s must be a boolean" surface name)
;;

let count_field ~surface name fields =
  let* value = field ~surface name fields in
  match value with
  | `Int n when n >= 0 -> Ok n
  | _ -> Error (Printf.sprintf "%s.%s must be a count" surface name)
;;

let volume_field ~surface name fields =
  let* value = field ~surface name fields in
  match value with
  | `Null -> Ok None
  | `String volume_name when String.trim volume_name <> "" -> Ok (Some volume_name)
  | _ -> Error (Printf.sprintf "%s.%s must be a volume name or null" surface name)
;;

let verdict_of_json index json =
  let surface = Printf.sprintf "%s.keepers[%d]" answer_surface index in
  let* fields = object_fields ~surface json in
  let* () = Json_util.reject_unknown_fields ~surface ~allowed:verdict_fields fields in
  let* keeper_name = Json_util.require_field_string ~surface "keeper_name" fields in
  let* work_volume = volume_field ~surface "work_volume" fields in
  let* build_volume = volume_field ~surface "build_volume" fields in
  let* kind_name = Json_util.require_field_string ~surface "outcome_kind" fields in
  let* kind =
    match outcome_kind_of_string kind_name with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "%s.outcome_kind %S is not an outcome" surface kind_name)
  in
  let* outcome = Json_util.require_field_string ~surface "outcome" fields in
  Ok { keeper_name; work_volume; build_volume; kind; outcome }
;;

let summary_of_json json =
  let surface = answer_surface ^ ".summary" in
  let* fields = object_fields ~surface json in
  let* () = Json_util.reject_unknown_fields ~surface ~allowed:summary_fields fields in
  let* kept = count_field ~surface "kept" fields in
  let* reclaim_candidates = count_field ~surface "reclaim_candidates" fields in
  let* reclaimed = count_field ~surface "reclaimed" fields in
  let* reclaim_failed = count_field ~surface "reclaim_failed" fields in
  Ok { kept; reclaim_candidates; reclaimed; reclaim_failed }
;;

let of_json json =
  let surface = answer_surface in
  let* fields = object_fields ~surface json in
  let* () = Json_util.reject_unknown_fields ~surface ~allowed:answer_fields fields in
  let* executed = bool_field ~surface "executed" fields in
  let* image_given = bool_field ~surface "image_given" fields in
  let* foreign_volumes = Json_util.require_field_string_list ~surface "foreign_volumes" fields in
  let* keepers_json = field ~surface "keepers" fields in
  let* keepers =
    match keepers_json with
    | `List items ->
      let rec collect index acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
          let* verdict = verdict_of_json index item in
          collect (index + 1) (verdict :: acc) rest
      in
      collect 0 [] items
    | _ -> Error (surface ^ ".keepers must be a list")
  in
  let* unlisted_keepers =
    Json_util.require_field_string_list ~surface "unlisted_keepers" fields
  in
  let* () =
    if List.exists (fun name -> String.equal (String.trim name) "") unlisted_keepers
    then Error (surface ^ ".unlisted_keepers holds a blank keeper name")
    else if (not executed) && not (List.is_empty unlisted_keepers)
    then Error (surface ^ ".unlisted_keepers is only written by an answer that executed")
    else Ok ()
  in
  let* summary_json = field ~surface "summary" fields in
  let* written = summary_of_json summary_json in
  let t = { executed; image_given; foreign_volumes; keepers; unlisted_keepers } in
  if summary_equal written (summary t)
  then Ok t
  else Error (surface ^ ".summary does not match its keepers")
;;
