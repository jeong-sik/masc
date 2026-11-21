(** Explicit Memory writes through the Keeper's write tool. *)

let memory_id digit = "sha256:" ^ String.make 64 digit

(* [lstat], not [Sys.is_directory]: a symlink to a directory outside the
   temporary tree is removed as a link, never followed into. *)
let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | S_LNK | S_CHR | S_BLK | S_FIFO | S_SOCK; _ } ->
    Unix.unlink path
;;

let with_temp_dir f =
  let dir = Filename.temp_file "keeper-memory-write-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
;;

(* The Memory tools write through the Keeper's Memory writer, so every case
   runs in an Eio loop and a Keeper gets its writer before its first tool
   call. *)
let tool_case name speed body =
  Alcotest.test_case name speed (Masc_test_deps.Memory_tool_case.run body)
;;

let fact claim : Masc.Keeper_memory_os_types.fact =
  let now = Time_compat.now () in
  Masc.Keeper_memory_os_types.observed ~claim
    ~category:Masc.Keeper_memory_os_types.Fact ~now
    ~origin:{ kind = Masc.Keeper_memory_os_types.Authored; trace_id = "" }
;;

(* A crash mid-append leaves a line with no newline. The next absorb commits
   anyway: the append cuts the torn line back to the last complete row before
   it writes. A librarian that could not commit would spend a provider call
   every cadence and never get past the torn line on its own. *)
let test_a_torn_tail_does_not_stop_the_next_absorb () =
  let keeper_id = "torn-tail-keeper" in
  let absorbed digit =
    let f = fact (Printf.sprintf "an absorbed claim %c" digit) in
    { Masc.Keeper_memory_absorbed.recorded_at = Time_compat.now ()
    ; trace_id = "torn-tail"
    ; memory_id = Masc.Keeper_memory_os_types.memory_id f
    ; into = memory_id 'c'
    ; fact = f
    }
  in
  let append ~keepers_dir record =
    Masc.Keeper_memory_absorbed.append_all ~keepers_dir ~keeper_id [ record ]
  in
  let path_in keepers_dir =
    Masc.Keeper_memory_absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  (* One row as the store itself writes it, so the fixture below is not a
     hand-built guess at the format. *)
  let complete_row =
    with_temp_dir (fun donor ->
      match append ~keepers_dir:donor (absorbed 'a') with
      | Error error ->
        Alcotest.fail (Masc.Keeper_memory_absorbed.append_error_to_string error)
      | Ok () -> In_channel.with_open_text (path_in donor) In_channel.input_all)
  in
  with_temp_dir (fun keepers_dir ->
    let path = path_in keepers_dir in
    (* the complete row, then the head of one a crash never finished *)
    Out_channel.with_open_text path (fun oc ->
      Out_channel.output_string oc (complete_row ^ "{\"recorded_at\":\"2026-09-18"));
    (match append ~keepers_dir (absorbed 'b') with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf
         "a torn tail must not stop the next absorb: %s"
         (Masc.Keeper_memory_absorbed.append_error_to_string error));
    let lines =
      In_channel.with_open_text path In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun line -> line <> "")
    in
    Alcotest.(check int)
      "the complete row and the new one, the torn head gone"
      2
      (List.length lines);
    List.iter
      (fun line ->
         match Yojson.Safe.from_string line with
         | _ -> ()
         | exception Yojson.Json_error detail ->
           Alcotest.failf "a line left behind does not decode: %s (%s)" line detail)
      lines)
;;

let () =
  Alcotest.run
    "keeper_memory_write_absorbed"
    [ ( "failure class"
      , [ tool_case
            "a torn tail does not stop the next absorb"
            `Quick
            test_a_torn_tail_does_not_stop_the_next_absorb
        ] )
    ]
;;
