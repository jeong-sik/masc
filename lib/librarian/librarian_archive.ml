module Types = Keeper_memory_os_types
module Log = Librarian_log
module Log_store = Librarian_log_store
module Codec = Librarian_log_codec
module By_id = Map.Make (String)

type left =
  { fact : Types.fact
  ; removal : Librarian_effects.removal
  ; at : float
  ; line_at : int
  }

type t =
  { left : left list
  ; unreadable : int
  }

type seen =
  { gone : (int * left) By_id.t
  ; removals : int
  ; unreadable : int
  }

let left_to_json (entry : left) =
  `Assoc
    [ "fact", Types.fact_to_json entry.fact
    ; "removal", Codec.removal_to_json entry.removal
    ; "at", `Float entry.at
    ; "line_at", `Int entry.line_at
    ]
;;

let left_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () = Types.exact_field_names_result [ "fact"; "removal"; "at"; "line_at" ] fields in
    let* fact_json = Types.wire_json_field "fact" fields in
    let* fact = Types.wire_at (Types.Wire_field "fact") (Types.fact_of_json fact_json) in
    let* removal_json = Types.wire_json_field "removal" fields in
    let* removal =
      Types.wire_at (Types.Wire_field "removal") (Codec.removal_of_json removal_json)
    in
    let* at = Types.wire_number_field "at" fields in
    let* line_at = Types.wire_int_field "line_at" fields in
    Ok { fact; removal; at; line_at }
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    Types.wire_here Types.Expected_object
;;

let record_left seen (entry : left) =
  { seen with
    gone = By_id.add (Types.memory_id entry.fact) (seen.removals, entry) seen.gone
  ; removals = seen.removals + 1
  }
;;

let after_commit seen ~line_at (commit : Log.commit) =
  let seen =
    List.fold_left
      (fun seen (fact, removal) ->
         record_left seen { fact; removal; at = commit.at; line_at })
      seen
      commit.effects.removed
  in
  { seen with
    gone =
      List.fold_left
        (fun gone fact -> By_id.remove (Types.memory_id fact) gone)
        seen.gone
        commit.effects.added
  }
;;

let fold_cold_archive archive_path init =
  if not (Sys.file_exists archive_path)
  then Ok init
  else
    Private_jsonl_scan.fold archive_path ~rows_per_read:128 ~init ~f:(fun seen ~at:(_ : int) row ->
      match Yojson.Safe.from_string row with
      | exception Yojson.Json_error (_ : string) -> { seen with unreadable = seen.unreadable + 1 }
      | json ->
        (match left_of_json json with
         | Ok entry -> record_left seen entry
         | Error (_ : Types.wire_error) -> { seen with unreadable = seen.unreadable + 1 }))
;;

let write_cold_archive ~archive_path entries =
  let dir = Filename.dirname archive_path in
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Printexc.to_string exn)
  | () ->
    let body =
      entries
      |> List.map (fun entry -> Yojson.Safe.to_string (left_to_json entry) ^ "\n")
      |> String.concat ""
    in
    Fs_compat.save_file_atomic_strict archive_path body
;;

let read path ~current =
  let archive_path = Log_store.archive_path_of_log_path path in
  let initial = { gone = By_id.empty; removals = 0; unreadable = 0 } in
  match fold_cold_archive archive_path initial with
  | Error _ as error -> error
  | Ok after_cold ->
    let after seen ({ at; line } : Log_store.scanned) =
      match line with
      | Error (_ : Log_store.undecodable) -> { seen with unreadable = seen.unreadable + 1 }
      | Ok (Started _) -> seen
      | Ok (Committed commit) -> after_commit seen ~line_at:at commit
    in
    (match Log_store.fold path ~init:after_cold ~f:after with
     | Error _ as error -> error
     | Ok { gone; unreadable; removals = (_ : int) } ->
       let gone =
         List.fold_left (fun gone fact -> By_id.remove (Types.memory_id fact) gone) gone current
       in
       let in_order =
         List.sort
           (fun (a, (_ : left)) (b, (_ : left)) -> Int.compare a b)
           (List.map snd (By_id.bindings gone))
       in
       Ok { left = List.map snd in_order; unreadable })
;;
