(** [Dated_jsonl] reads a day file's tail, splits it and parses its rows as one
    job on the process domain pool when one is installed, and its backwards
    scans take one chunk per pool job while the caller's filter stays on the
    fiber. These tests read the same store inline and through a one-domain
    pool and expect identical results: order, offsets, malformed rows, the
    direct tail loader, the latest-entry scan and collect_matching. *)
open Alcotest

let counter = ref 0

let tmpdir prefix =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%.0f" prefix !counter (Unix.getpid ()) (Unix.gettimeofday ()))
  in
  Unix.mkdir dir 0o755;
  dir
;;

let entry_to_string = function
  | Dated_jsonl.Parsed json -> "parsed:" ^ Yojson.Safe.to_string json
  | Dated_jsonl.Malformed_json _ -> "malformed"
;;

let only_day_file base_dir =
  let first path = Sys.readdir path |> Array.to_list |> List.sort compare |> List.hd in
  let month_path = Filename.concat base_dir (first base_dir) in
  Filename.concat month_path (first month_path)
;;

(* Every public reader this change routes through the pool, projected to
   strings so inline and pooled runs compare directly. *)
let read_everything store day_file =
  let recent = Dated_jsonl.read_recent store 2 |> List.map Yojson.Safe.to_string in
  let offset = Dated_jsonl.read_recent ~offset:1 store 2 |> List.map Yojson.Safe.to_string in
  let strict =
    match Dated_jsonl.read_recent_result store 10 with
    | Ok entries -> List.map entry_to_string entries
    | Error error -> [ "error:" ^ Dated_jsonl.read_error_to_string error ]
  in
  let filtered =
    Dated_jsonl.filter_map_recent store 10 ~f:(function
      | `Assoc fields -> List.assoc_opt "n" fields |> Option.map Yojson.Safe.to_string
      | _ -> None)
  in
  let tail = Dated_jsonl.load_tail_lines day_file ~max_lines:2 in
  let latest =
    match
      Dated_jsonl.find_latest_entry_result store (function
        | Dated_jsonl.Parsed (`Assoc fields) ->
          (match List.assoc_opt "n" fields with
           | Some (`Int 2) -> Some "n=2"
           | Some _ | None -> None)
        | Dated_jsonl.Parsed _ | Dated_jsonl.Malformed_json _ -> None)
    with
    | Ok (Some found) -> [ found ]
    | Ok None -> [ "none" ]
    | Error error -> [ "error:" ^ Dated_jsonl.read_error_to_string error ]
  in
  let matching =
    Dated_jsonl.collect_matching store 2 ~f:(function
      | `Assoc fields -> List.assoc_opt "n" fields |> Option.map Yojson.Safe.to_string
      | _ -> None)
  in
  [ recent; offset; strict; filtered; tail; latest; matching ]
;;

let with_pool env f =
  Eio.Switch.run @@ fun sw ->
  let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
  Domain_pool_ref.set pool;
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests f
;;

let test_pool_and_inline_read_the_same () =
  Eio_main.run @@ fun env ->
  Fun.protect ~finally:Domain_pool_ref.clear_for_tests @@ fun () ->
  let base_dir = tmpdir "dated_jsonl_off_fiber" in
  let store = Dated_jsonl.create ~base_dir () in
  List.iter (fun n -> Dated_jsonl.append store (`Assoc [ ("n", `Int n) ])) [ 1; 2; 3 ];
  let day_file = only_day_file base_dir in
  (* One malformed row, newest: the strict reader reports it, the others skip it. *)
  let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 day_file in
  output_string oc "{not json\n";
  close_out oc;
  let inline = read_everything store day_file in
  let pooled = with_pool env (fun () -> read_everything store day_file) in
  check (list (list string)) "pooled reads equal inline reads" inline pooled;
  (match inline with
   | [ recent; _; strict; filtered; tail; latest; matching ] ->
     check (list string) "newest two parsed rows, oldest first"
       [ {|{"n":2}|}; {|{"n":3}|} ] recent;
     check int "strict read counts the malformed row" 4 (List.length strict);
     check (list string) "filter_map sees the parsed rows" [ "1"; "2"; "3" ] filtered;
     check (list string) "tail loader returns the raw last lines"
       [ {|{"n":3}|}; "{not json" ] tail;
     check (list string) "the latest matching entry is found past the malformed row" [ "n=2" ] latest;
     check (list string) "collect_matching keeps the newest two selected values" [ "2"; "3" ] matching
   | _ -> fail "read_everything shape changed")
;;

let () =
  run
    "dated_jsonl off fiber"
    [ ( "pool"
      , [ test_case "pooled reads equal inline reads" `Quick test_pool_and_inline_read_the_same ] )
    ]
;;
