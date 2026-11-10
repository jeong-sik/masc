open Result.Syntax

type change =
  | Added
  | Absorbed
  | Superseded
  | Dropped
[@@deriving enumerate]

let change_label = function
  | Added -> "added"
  | Absorbed -> "absorbed"
  | Superseded -> "superseded"
  | Dropped -> "dropped"
;;

type counts =
  { added : int
  ; absorbed : int
  ; superseded : int
  ; dropped : int
  }

let get counts = function
  | Added -> counts.added
  | Absorbed -> counts.absorbed
  | Superseded -> counts.superseded
  | Dropped -> counts.dropped
;;

let metric = Keeper_metrics.(to_string MemoryChanges)

let labels ~keeper_id ~pass change =
  [ "keeper", keeper_id
  ; "pass", Keeper_memory_commit_pass.to_label pass
  ; "change", change_label change
  ]
;;

let count ~keeper_id ~pass counts =
  List.iter
    (fun change ->
       Otel_metric_store.inc_counter
         metric
         ~labels:(labels ~keeper_id ~pass change)
         ~delta:(float_of_int (get counts change))
         ())
    all_of_change
;;

type by_pass = (Keeper_memory_commit_pass.t * counts) list

let since_start ~keeper_id =
  List.map
    (fun pass ->
       let read change =
         Otel_metric_store.metric_value_or_zero metric ~labels:(labels ~keeper_id ~pass change) ()
         |> int_of_float
       in
       ( pass
       , { added = read Added
         ; absorbed = read Absorbed
         ; superseded = read Superseded
         ; dropped = read Dropped
         } ))
    Keeper_memory_commit_pass.all
;;

let by_pass_to_json by_pass =
  `Assoc
    (List.map
       (fun (pass, counts) ->
          ( Keeper_memory_commit_pass.to_label pass
          , `Assoc
              (List.map (fun change -> change_label change, `Int (get counts change)) all_of_change)
          ))
       by_pass)
;;

(* The reader finds every label below and the lengths agree here, so an
   accepted object holds each label once and nothing else. A table from a
   build that counts another pass or change is refused, not read in part. *)
let members ~what labels = function
  | `Assoc fields when List.compare_lengths fields labels = 0 -> Ok fields
  | `Assoc _ -> Error (Printf.sprintf "%s must hold exactly %s" what (String.concat ", " labels))
  | other -> Error (Printf.sprintf "%s must be an object, got %s" what (Yojson.Safe.to_string other))
;;

let member ~what fields label =
  match List.assoc_opt label fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s has no %S" what label)
;;

let counts_of_json ~what json =
  let* fields = members ~what (List.map change_label all_of_change) json in
  let read change =
    let* value = member ~what fields (change_label change) in
    match value with
    | `Int count when count >= 0 -> Ok count
    | other ->
      Error
        (Printf.sprintf "%s.%s must be a non-negative int, got %s" what (change_label change)
           (Yojson.Safe.to_string other))
  in
  let* added = read Added in
  let* absorbed = read Absorbed in
  let* superseded = read Superseded in
  let* dropped = read Dropped in
  Ok { added; absorbed; superseded; dropped }
;;

let by_pass_of_json json =
  let what = "changes_since_start" in
  let passes = Keeper_memory_commit_pass.all in
  let* fields = members ~what (List.map Keeper_memory_commit_pass.to_label passes) json in
  List.fold_right
    (fun pass by_pass ->
       let* by_pass = by_pass in
       let label = Keeper_memory_commit_pass.to_label pass in
       let* value = member ~what fields label in
       let* counts = counts_of_json ~what:(what ^ "." ^ label) value in
       Ok ((pass, counts) :: by_pass))
    passes
    (Ok [])
;;
