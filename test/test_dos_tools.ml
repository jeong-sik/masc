(* DOS lane tools — the seven tools through Tool_misc.dispatch.

   The machine needs no image from outside: the tests assemble a COM program
   of their own, so CI carries no game. What they pin: the no-machine
   refusal, the inventory listing, that a loaded program's screen text comes
   back readable, that waiting_for_key marks the turn, that a key reaches the
   guest and lands in the ledger under the caller's name, that a key name the
   machine has no key for is refused before anything is pressed, the per-call
   step cap, memory reads, and the read-only classification. *)

open Alcotest
open Masc

let dispatch ~base_path ?(agent = "dos-test") name assoc =
  let ctx : Tool_misc.context =
    { config = Workspace.default_config base_path; agent_name = agent; help_schemas = [] }
  in
  match Tool_misc.dispatch ctx ~name ~args:(`Assoc assoc) with
  | Some result -> result
  | None -> fail (name ^ " is not dispatched by the misc tool owner")
;;

let with_workspace f =
  let base_path = Filename.temp_dir "masc-dos-tools-" "" in
  Fun.protect
    ~finally:(fun () ->
      (* The machine is process-global: a test that leaves one loaded would
         hand it to the next one. *)
      ignore (Dos_lane.eject () : (unit, Dos_lane.error) result);
      Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let string_field name result =
  match member name (Tool_result.data result) with
  | Some (`String s) -> s
  | _ -> fail (Printf.sprintf "no %s in %s" name (Tool_result.message result))
;;

let bool_field name result =
  match member name (Tool_result.data result) with
  | Some (`Bool b) -> b
  | _ -> fail (Printf.sprintf "no %s in %s" name (Tool_result.message result))
;;

let is_completed result = Tool_result.failure_class result = None

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

(* A COM image that prints HI, then loops on the BIOS key read until one
   arrives, then terminates. The loop is the real idiom: a blocking read with
   an empty ring returns AX=0 here rather than blocking the whole process, and
   every DOS runtime spins on that. A program that fell straight through would
   exit before anyone could press anything.

   org 0x100: mov ah,9 / mov dx,msg / int 21h
              wait: mov ah,0 / int 16h / or ax,ax / jz wait
              int 20h / "HI$" *)
let hello_com =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755
  end
;;

let install_program ~base_path name contents =
  let dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos"
    |> fun d -> Filename.concat d "programs"
  in
  mkdir_p dir;
  Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
    output_string oc contents)
;;

let load ~base_path name = dispatch ~base_path "masc_dos_load" [ ("program", `String name) ]

(* Setup for the tests that are about what happens after a load. The load's
   own result has its own test. *)
let boot ~base_path name = ignore (load ~base_path name : Tool_result.t)

let test_no_machine () =
  with_workspace (fun base_path ->
    let result = dispatch ~base_path "masc_dos_screen" [] in
    check bool "screen without a machine is refused" false (is_completed result);
    check bool "and says which tool starts one" true
      (contains "masc_dos_load" (Tool_result.message result)))
;;

let test_inventory_when_unnamed () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let result = dispatch ~base_path "masc_dos_load" [] in
    check bool "listing succeeds" true (is_completed result);
    match member "programs_available" (Tool_result.data result) with
    | Some (`List [ `String name ]) -> check string "the inventory" "hello.com" name
    | _ -> fail "no programs_available")
;;

let test_load_runs_to_the_first_key_request () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let result = load ~base_path "hello.com" in
    check bool "load succeeds" true (is_completed result);
    check string "the program name" "hello.com" (string_field "program" result);
    check bool "its output is on the screen" true
      (contains "HI" (string_field "screen_text" result));
    (* The program is spinning on INT 16h with an empty ring and its screen
       has stopped moving. Both halves are why the load stopped here instead
       of burning its whole budget. *)
    check bool "it settled" true (bool_field "settled" result);
    check bool "it is waiting for a key" true (bool_field "waiting_for_key" result);
    check bool "and has not exited" false (bool_field "exited" result))
;;

let test_press_reaches_the_guest_and_the_ledger () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path ~agent:"vincent" "masc_dos_press"
        [ ("keys", `List [ `String "enter" ]) ]
    in
    check bool "press succeeds" true (is_completed result);
    (* The guest took the key and ran into INT 20h. *)
    check bool "the program finished" true (bool_field "exited" result);
    match Dos_lane.ledger () with
    | [ entry ] ->
      check string "the ledger names the caller" "vincent" entry.Dos_lane.who;
      check string "and the key" "enter" entry.Dos_lane.key_name
    | entries ->
      fail (Printf.sprintf "expected one ledger entry, got %d" (List.length entries)))
;;

let test_unknown_key_is_refused () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path "masc_dos_press"
        [ ("keys", `List [ `String "enter"; `String "hyperspace" ]) ]
    in
    check bool "the call is refused" false (is_completed result);
    (* Refused before anything was pressed: the good key in front of the bad
       one must not reach the ring, or half a sequence lands in the game. *)
    check int "nothing was pressed" 0 (List.length (Dos_lane.ledger ())))
;;

let test_step_cap () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path "masc_dos_step"
        [ ("steps", `Int (Dos_lane.max_steps_per_call + 1)) ]
    in
    check bool "over the cap is refused" false (is_completed result);
    check bool "and names the cap" true
      (contains (string_of_int Dos_lane.max_steps_per_call) (Tool_result.message result)))
;;

let test_peek_reads_the_text_page () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path "masc_dos_peek" [ ("address", `String "b8000"); ("length", `Int 4) ]
    in
    check bool "peek succeeds" true (is_completed result);
    (* 'H' with the default attribute, then 'I': character and attribute
       alternate in the text page. *)
    check string "the first two cells" "48074907" (string_field "hex" result))
;;

let test_read_only_classification () =
  let read_only name =
    match Tool_schemas_misc.misc_operation_of_tool_name name with
    | Some op -> Tool_misc.is_read_only op
    | None -> fail (name ^ " is not a misc operation")
  in
  check bool "screen reads" true (read_only "masc_dos_screen");
  check bool "peek reads" true (read_only "masc_dos_peek");
  check bool "load changes the machine" false (read_only "masc_dos_load");
  check bool "press changes the machine" false (read_only "masc_dos_press");
  check bool "step changes the machine" false (read_only "masc_dos_step")
;;

let test_every_tool_is_declared () =
  List.iter
    (fun name ->
      match Tool_schemas_misc.misc_operation_of_tool_name name with
      | None -> fail (name ^ " has no misc operation")
      | Some op ->
        (match Tool_schemas_misc.misc_registered_schema op with
         | Some (schema : Masc_domain.tool_schema) ->
           check string "schema name" name schema.name
         | None -> fail (name ^ " registers no schema")))
    [ "masc_dos_load"; "masc_dos_eject"; "masc_dos_screen"; "masc_dos_step";
      "masc_dos_press"; "masc_dos_type"; "masc_dos_peek" ]
;;

let () =
  run "dos-lane-tools"
    [ ( "tools"
      , [ test_case "no machine" `Quick test_no_machine
        ; test_case "inventory" `Quick test_inventory_when_unnamed
        ; test_case "load" `Quick test_load_runs_to_the_first_key_request
        ; test_case "press" `Quick test_press_reaches_the_guest_and_the_ledger
        ; test_case "unknown key" `Quick test_unknown_key_is_refused
        ; test_case "step cap" `Quick test_step_cap
        ; test_case "peek" `Quick test_peek_reads_the_text_page
        ; test_case "read-only" `Quick test_read_only_classification
        ; test_case "declared" `Quick test_every_tool_is_declared
        ] )
    ]
;;
