(** RFC-0474 L4f: [Audit.read_recent] answers from an index it advances over
    appended bytes, and must give the answer the backward scan it replaced
    gave. [scan] below is that scan: newest row first, stop at the [n]-th
    match, refuse a malformed row, or for a Keeper-scoped read a row that does
    not name exactly one string Keeper, when the scan reaches it.

    One store goes through appends to the newest file, a late append to an
    older file, a new day file, a removed day file, a rewritten day file, a
    malformed row and an unowned row. After each step every Keeper, the
    unscoped read and several [n] are compared. The index is process state,
    so the steps share it as the server's reads do. *)

module Audit = Keeper_approval.Audit
open Alcotest

let temp_dir () =
  let dir = Filename.temp_file "test_approval_audit_recent_index_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let rec cleanup_dir path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> cleanup_dir (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let audit_dir base_path =
  Filename.concat (Filename.concat base_path ".masc") "audit-approvals"
;;

let day_path ~base_path ~month ~day =
  let dir = Filename.concat (audit_dir base_path) month in
  mkdir_p dir;
  Filename.concat dir day
;;

let append_lines path lines =
  let oc = open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> List.iter (fun line -> output_string oc (line ^ "\n")) lines)
;;

let serial = ref 0

let row keeper =
  incr serial;
  Yojson.Safe.to_string
    (`Assoc
        [ "ts", `Float (float_of_int !serial)
        ; "event", `String "pending"
        ; "id", `String (Printf.sprintf "approval-%d" !serial)
        ; "keeper", `String keeper
        ; "tool", `String "tool_execute"
        ])
;;

let rows keeper count = List.init count (fun _ -> row keeper)

(* The backward scan [read_recent] used before the index. *)
let scan ~base_path ?keeper_name ~n () =
  let store =
    Dated_jsonl.open_store
      Dated_jsonl.Store.(at (root_of_base_path ~base_path) Root.Audit_approvals)
  in
  let selected = ref [] in
  let count = ref 0 in
  let select = function
    | Dated_jsonl.Malformed_json _ -> Some (Error "malformed row")
    | Dated_jsonl.Parsed json ->
      let matches =
        match keeper_name with
        | None -> Ok true
        | Some name ->
          (match json with
           | `Assoc fields ->
             (match List.filter (fun (key, _) -> String.equal key "keeper") fields with
              | [ (_, `String owner) ] -> Ok (String.equal name owner)
              | _ -> Error "unowned row")
           | _ -> Error "unowned row")
      in
      (match matches with
       | Error detail -> Some (Error detail)
       | Ok false -> None
       | Ok true ->
         selected := json :: !selected;
         incr count;
         if !count = n then Some (Ok (List.rev !selected)) else None)
  in
  match Dated_jsonl.find_latest_entry_result store select with
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
  | Ok (Some result) -> result
  | Ok None -> Ok (List.rev !selected)
;;

let readers = [ Some "alpha"; Some "beta"; Some "gamma"; Some "absent"; None ]
let sizes = [ 1; 2; 5; 20; Audit.read_recent_max_rows ]

let agrees_with_scan ~base_path step =
  List.iter
    (fun keeper_name ->
       List.iter
         (fun n ->
            let label =
              Printf.sprintf "%s: %s n=%d" step (Option.value ~default:"*" keeper_name) n
            in
            match
              ( Audit.read_recent ~base_path ?keeper_name ~n ()
              , scan ~base_path ?keeper_name ~n () )
            with
            | Ok index, Ok scanned ->
              check int (label ^ " count") (List.length scanned) (List.length index);
              check bool (label ^ " rows") true (List.for_all2 Yojson.Safe.equal index scanned)
            | Error _, Error _ -> ()
            | Ok _, Error detail -> failf "%s: index answered, scan refused (%s)" label detail
            | Error error, Ok _ ->
              failf "%s: index refused (%s), scan answered" label
                (Audit.read_error_to_string error))
         sizes)
    readers
;;

let test_index_answers_as_the_backward_scan () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  let path month day = day_path ~base_path ~month ~day in
  let sep30 = path "2026-09" "30.jsonl" in
  let oct01 = path "2026-10" "01.jsonl" in
  let oct02 = path "2026-10" "02.jsonl" in
  (* gamma has rows only in the oldest file, so a gamma read reaches it. *)
  append_lines sep30 (rows "gamma" 3 @ rows "alpha" 10 @ rows "beta" 2);
  append_lines oct01 (rows "alpha" 20 @ rows "beta" 1);
  append_lines oct02 (rows "alpha" 5);
  agrees_with_scan ~base_path "initial";
  agrees_with_scan ~base_path "unchanged";
  (* Newest file, a late append to an older one, a new day file. *)
  append_lines oct02 (rows "beta" 3);
  append_lines oct01 (rows "gamma" 2);
  append_lines (path "2026-10" "03.jsonl") (rows "gamma" 1);
  agrees_with_scan ~base_path "appended";
  (* Removal and rewrite come before any refused row: a refused row newer
     than every read would hide a removed file's rows from the comparison. *)
  Sys.remove sep30;
  agrees_with_scan ~base_path "oldest day file removed";
  let oct03 = path "2026-10" "03.jsonl" in
  Sys.remove oct03;
  append_lines oct03 (rows "gamma" 1);
  agrees_with_scan ~base_path "day file rewritten";
  check bool "the index read the rewritten file" true
    (match Audit.read_recent ~base_path ~keeper_name:"gamma" ~n:1 () with
     | Ok [ `Assoc fields ] ->
       List.assoc_opt "id" fields = Some (`String (Printf.sprintf "approval-%d" !serial))
     | Ok _ | Error _ -> false);
  append_lines oct01 [ "{\"event\": \"pending\", \"keeper\": " ];
  agrees_with_scan ~base_path "malformed row";
  append_lines oct03 [ "{\"event\":\"pending\",\"id\":\"x\"}" ];
  agrees_with_scan ~base_path "unowned row"
;;

let test_bounds () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  append_lines (day_path ~base_path ~month:"2026-10" ~day:"01.jsonl") (rows "alpha" 2);
  check bool "n <= 0 reads nothing" true
    (Audit.read_recent ~base_path ~keeper_name:"alpha" ~n:0 () = Ok []);
  check bool "n above the kept rows is refused" true
    (Result.is_error
       (Audit.read_recent ~base_path ~keeper_name:"alpha"
          ~n:(Audit.read_recent_max_rows + 1) ()));
  check int "a missing store reads empty" 0
    (match Audit.read_recent ~base_path:(Filename.concat base_path "nowhere") ~n:5 () with
     | Ok rows -> List.length rows
     | Error error -> failf "missing store refused: %s" (Audit.read_error_to_string error))
;;

let () =
  run "approval_audit_recent_index"
    [ ( "read_recent"
      , [ test_case "answers as the backward scan through store changes" `Quick
            test_index_answers_as_the_backward_scan
        ; test_case "bounds" `Quick test_bounds
        ] )
    ]
;;
