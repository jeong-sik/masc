(** Sub-board policy and CRUD for one store. See the interface for the
    same-store persistence boundary and retained snapshot-error behavior. *)

open Board_core_persist
open Result.Syntax

let sub_board_to_yojson = Board_sub_board_json.sub_board_to_yojson
let parse_sub_board_members = Board_sub_board_json.parse_sub_board_members
let sub_board_of_yojson = Board_sub_board_json.sub_board_of_yojson

type snapshot_change =
  | Replace_sub_board of sub_board
  | Remove_sub_board of Sub_board_id.t

let changed_sub_boards_jsonl_unlocked store change =
  let buf = Buffer.create 1024 in
  Hashtbl.iter
    (fun id (sb : sub_board) ->
       let row = match change with
         | Replace_sub_board updated ->
           Some (if String.equal id (Sub_board_id.to_string updated.id) then updated else sb)
         | Remove_sub_board removed ->
           if String.equal id (Sub_board_id.to_string removed) then None else Some sb
       in
       Option.iter (fun row ->
         Buffer.add_string buf (Yojson.Safe.to_string (sub_board_to_yojson row));
         Buffer.add_char buf '\n') row)
    store.sub_boards;
  Buffer.contents buf
;;

let save_sub_boards_jsonl store content =
  try
    let* () = ensure_masc_dir ~where:"rewrite_sub_boards" store in
    let path = sub_boards_path store in
    match Fs_compat.save_file_atomic path content with
    | Ok () -> Ok ()
    | Error msg -> persist_io_error ~where:"rewrite_sub_boards" msg
  with
  | Sys_error msg -> persist_io_error ~where:"rewrite_sub_boards" msg
;;

let append_sub_board store (sb : sub_board) =
  try
    let* () = ensure_masc_dir ~where:"append_sub_board" store in
    let path = sub_boards_path store in
    Fs_compat.append_file path (Yojson.Safe.to_string (sub_board_to_yojson sb) ^ "\n");
    Ok ()
  with
  | Sys_error msg -> persist_io_error ~where:"append_sub_board" msg
;;

let valid_slug_pattern = Re.Pcre.re {|^[a-z0-9][a-z0-9_-]*$|} |> Re.compile

let create_sub_board
      store
      ~slug
      ~name
      ~description
      ~owner
      ?(members = [])
      ?(access = Open)
      ()
  : (sub_board, board_error) Result.t
  =
  let* () = require_persisted_snapshot_readable store.sub_boards_load_result in
  let slug = String.lowercase_ascii (String.trim slug) in
  if
    String.length slug < 1
    || String.length slug > 64
    || not (Re.execp valid_slug_pattern slug)
  then
    Error
      (Validation_error
         (Printf.sprintf
            "Invalid sub-board slug %S: must be 1-64 lowercase alphanumeric/-/_"
            slug))
  else (
    match Agent_id.of_string owner with
    | Error e -> Error e
    | Ok owner_id ->
      (match parse_sub_board_members ~owner:owner_id members with
       | Error e -> Error e
       | Ok members ->
         (* Stage without mutation. The final uniqueness check is serialized
            with every runtime sub-board policy mutation before append. *)
         let staged =
           with_lock store (fun () ->
             if Hashtbl.mem store.sub_boards_by_slug slug
             then
               Error
                 (Already_exists (Printf.sprintf "Sub-board slug %S already exists" slug))
             else (
               let id = Sub_board_id.generate () in
               Ok
                 { id
                 ; slug
                 ; name = String.trim name
                 ; description = String.trim description
                 ; owner = owner_id
                 ; members
                 ; access
                 ; created_at = Time_compat.now ()
                 ; post_count = 0
                 }))
         in
         match staged with
         | Error _ as error -> error
         | Ok sb ->
           with_persist_lock store (fun () ->
             let* () =
               with_lock store (fun () ->
                 if Hashtbl.mem store.sub_boards_by_slug slug
                 then
                   Error
                     (Already_exists
                        (Printf.sprintf "Sub-board slug %S already exists" slug))
                 else Ok ())
             in
             let* () = append_sub_board store sb in
             with_lock store (fun () ->
               Hashtbl.replace store.sub_boards (Sub_board_id.to_string sb.id) sb;
               Hashtbl.replace store.sub_boards_by_slug slug
                 (Sub_board_id.to_string sb.id);
               Ok sb))))
;;


let update_sub_board
      store
      ~sub_board_id
      ?name
      ?description
      ?members
      ?access
      ()
  : (sub_board, board_error) Result.t
  =
  let* () = require_persisted_snapshot_readable store.sub_boards_load_result in
  with_persist_lock store (fun () ->
    let result =
      with_lock store (fun () ->
        let sb_opt =
          match Hashtbl.find_opt store.sub_boards sub_board_id with
          | Some sb -> Some sb
          | None ->
            (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
             | Some id -> Hashtbl.find_opt store.sub_boards id
             | None -> None)
        in
        match sb_opt with
        | None ->
          Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
        | Some sb ->
          let members_result =
            match members with
            | None -> Ok sb.members
            | Some raw -> parse_sub_board_members ~owner:sb.owner raw
          in
          (match members_result with
           | Error _ as error -> error
           | Ok members ->
             let updated =
               { sb with
                 (* DET-OK: omitted text fields preserve existing typed values. *)
                 name = Option.value ~default:sb.name (Option.map String.trim name)
               ; description =
                   Option.value
                     ~default:sb.description
                     (Option.map String.trim description)
               ; members
               (* DET-OK: omitted access keeps the existing typed policy. *)
               ; access = Option.value ~default:sb.access access
               }
             in
             Ok (updated, changed_sub_boards_jsonl_unlocked store
               (Replace_sub_board updated))))
    in
    match result with
    | Error _ as error -> error
    | Ok (updated, content) ->
      let* () = save_sub_boards_jsonl store content in
      with_lock store (fun () ->
        Hashtbl.replace store.sub_boards (Sub_board_id.to_string updated.id) updated;
        Ok updated))
;;

let get_sub_board store ~sub_board_id : (sub_board, board_error) Result.t =
  with_lock store (fun () ->
    match Hashtbl.find_opt store.sub_boards sub_board_id with
    | Some sb -> Ok (sub_board_with_post_count_unlocked store sb)
    | None ->
      (* fallback: try slug *)
      (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
       | Some id ->
         (match Hashtbl.find_opt store.sub_boards id with
          | Some sb -> Ok (sub_board_with_post_count_unlocked store sb)
          | None ->
            Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id)))
       | None ->
         Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))))
;;

let list_sub_boards store : sub_board list =
  with_lock store (fun () ->
    let counts = sub_board_post_counts_unlocked store in
    Hashtbl.fold
      (fun _ sb acc -> sub_board_with_post_count counts sb :: acc)
      store.sub_boards
      []
    |> List.sort (fun (a : sub_board) (b : sub_board) ->
      compare a.created_at b.created_at))
;;

let delete_sub_board store ~sub_board_id : (unit, board_error) Result.t =
  let* () = require_persisted_snapshot_readable store.sub_boards_load_result in
  with_persist_lock store (fun () ->
    let snapshot =
      with_lock store (fun () ->
      let resolved_opt =
        match Hashtbl.find_opt store.sub_boards sub_board_id with
        | Some sb -> Some sb
        | None ->
          (match Hashtbl.find_opt store.sub_boards_by_slug sub_board_id with
           | None -> None
           | Some id ->
             (match Hashtbl.find_opt store.sub_boards id with
              | Some sb -> Some sb
              | None -> None))
      in
      match resolved_opt with
      | None ->
        Error (Invalid_id (Printf.sprintf "Sub-board not found: %s" sub_board_id))
      | Some sb ->
        Ok (sb, changed_sub_boards_jsonl_unlocked store (Remove_sub_board sb.id)))
    in
    match snapshot with
    | Error _ as e -> e
    | Ok (sb, content) ->
      let* () = save_sub_boards_jsonl store content in
      with_lock store (fun () ->
        Hashtbl.remove store.sub_boards (Sub_board_id.to_string sb.id);
        Hashtbl.remove store.sub_boards_by_slug sb.slug;
        (* Orphan policy: clear hearth on posts that belonged to this sub-board *)
        Hashtbl.iter
          (fun _ (post : post) ->
             match post.hearth with
             | Some h when String.equal h sb.slug ->
               let updated = { post with hearth = None } in
               Hashtbl.replace store.posts (Post_id.to_string post.id) updated;
               store.dirty_posts <- true;
               Hashtbl.replace store.dirty_post_ids (Post_id.to_string post.id) ()
             | _ -> ())
          store.posts;
        invalidate_post_caches store;
        Ok ()))
;;
