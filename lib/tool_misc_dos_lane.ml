(** DOS lane tools — the workspace DOS machine, reachable from a keeper.

    Follows RFC-0439 (the MSX machine lives in the server) for a second
    machine. [masc_dos_load] boots a program, [masc_dos_screen] reads it,
    [masc_dos_press] and [masc_dos_step] move its time, [masc_dos_eject] ends
    it. The machine is {!Dos_lane}'s: one per workspace, in this process,
    shared by every caller.

    The observation is text: a DOS text page is characters, and this lane
    hands them over as UTF-8 with code page 437 kept, so a keeper with no
    vision runtime reads the game directly (RFC-0414). What makes the lane
    playable is [settled]: the guest asked for a key {e and} the screen
    stopped moving. [waiting_for_key] alone is not that — a program in its
    own loop asks again 631 instructions after taking a key, with its
    repaint half-written. *)

open Tool_args

let reject ~tool_name ~start_time message =
  Tool_result.make_err ~tool_name ~class_:Tool_result.Workflow_rejection ~start_time message
;;

let observation_fields (o : Dos_lane.observation) =
  [ ("steps", `Int o.steps)
  ; ("video_mode", `String (Printf.sprintf "%02xh" o.video_mode))
  ; ("frame", `String (Printf.sprintf "%dx%d" o.width o.height))
  ; ("cs_ip", `String (Printf.sprintf "%04x:%04x" o.cs o.ip))
  ; ("exited", `Bool o.exited)
  ; ("exit_code", `Int o.exit_code)
  ; ("halted", `Bool o.halted)
  ; ("waiting_for_key", `Bool o.waiting_for_key)
  ; ("ticks", `Int o.ticks)
  ; ("screen_text", `String o.screen_text)
  ; ("program", match o.program with Some p -> `String p | None -> `Null)
  ; ("files", `List (List.map (fun f -> `String f) o.files))
  ]
;;

let ran_fields (r : Dos_lane.ran) =
  [ ("steps_run", `Int r.Dos_lane.steps_run)
  ; ("settled", `Bool r.Dos_lane.settled)
  ; ("input_requests", `Int r.Dos_lane.input_requests)
  ; ("keys_pressed", `Int r.Dos_lane.keys_pressed)
  ]
;;

let of_lane ?(extra = []) ~tool_name ~start_time
    (result : (Dos_lane.observation, Dos_lane.error) result) =
  match result with
  | Ok o ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc (observation_fields o @ extra))
      ()
  | Error ((Dos_lane.No_machine | Dos_lane.Invalid_request _) as e) ->
    reject ~tool_name ~start_time (Dos_lane.error_to_string e)
  | Error (Dos_lane.Unreadable _ as e) ->
    Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time
      (Dos_lane.error_to_string e)
;;

let of_lane_run ~tool_name ~start_time
    (result : (Dos_lane.observation * Dos_lane.ran, Dos_lane.error) result) =
  match result with
  | Ok (o, r) -> of_lane ~tool_name ~start_time ~extra:(ran_fields r) (Ok o)
  | Error e -> of_lane ~tool_name ~start_time (Error e)
;;

(* The lane's files live under <.masc>/dos: the ledger, and programs/ — the
   inventory an operator fills by hand. A DOS game is rarely one file, so a
   name in programs/ may be a directory: its executable boots and everything
   beside it is mounted where the guest opens files. A keeper never needs a
   host path. *)
let dos_dir ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos"
let programs_dir ~base_path = Filename.concat (dos_dir ~base_path) "programs"

let entries_of dir =
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> not (String.starts_with ~prefix:"." f))
    |> List.sort String.compare
  else []
;;

let programs_available ~base_path = entries_of (programs_dir ~base_path)
let read_file path = In_channel.with_open_bin path In_channel.input_all

let is_program_name name =
  let lower = String.lowercase_ascii name in
  Filename.check_suffix lower ".exe" || Filename.check_suffix lower ".com"
;;

(* Inside a directory the executable is the one named after the directory, or
   the only .exe/.com there. Two candidates and no name match is a question
   for the caller, not a guess: DOS game directories carry installers and
   setup programs beside the game. Returns the executable and the rest of the
   directory beside it, so its caller reads each file exactly once. *)
let executable_in dir =
  let files =
    List.filter (fun f -> not (Sys.is_directory (Filename.concat dir f))) (entries_of dir)
  in
  let programs = List.filter is_program_name files in
  let stem = String.lowercase_ascii (Filename.basename dir) in
  let named =
    List.filter (fun f -> String.equal (String.lowercase_ascii (Filename.remove_extension f)) stem) programs
  in
  match (named, programs) with
  | [ one ], _ | [], [ one ] ->
    Ok (one, List.filter (fun f -> not (String.equal f one)) files)
  | [], [] -> Error (Printf.sprintf "%s holds no .exe or .com" (Filename.basename dir))
  | _, many ->
    Error
      (Printf.sprintf "%s holds several programs (%s); name the one to boot"
         (Filename.basename dir)
         (String.concat ", " many))
;;

(* A program is a name in programs/, never a host path. The machine reads the
   file into guest memory and masc_dos_peek reads guest memory back out, so a
   caller-supplied path would be an arbitrary host-file read. The inventory is
   the whole filesystem this lane can see; an operator puts a game there.

   The name may be a file (boots alone) or a directory (boots with its data
   files mounted). It cannot climb out: a separator or a dot segment is
   refused before it reaches the filesystem. *)
let escapes name =
  String.contains name '/'
  || String.contains name '\\'
  || String.equal name ".."
  || String.starts_with ~prefix:"." name
;;

(* Spelling the name safely is not the whole boundary. Sys.file_exists and
   open both follow symbolic links, so an entry linked at a file outside
   programs/ would be read into guest memory and handed back out 256 bytes at
   a time by masc_dos_peek. The check is therefore on the resolved path, not
   on the spelling: everything this lane opens has to really live under
   programs/. A link inside the inventory still works; one that leaves it is
   refused. *)
let within ~root path =
  match (Unix.realpath root, Unix.realpath path) with
  | exception Unix.Unix_error _ -> None
  | root_real, real ->
    if String.equal real root_real
       || String.starts_with ~prefix:(root_real ^ Filename.dir_sep) real
    then Some real
    else None
;;

let left_inventory ~root shown =
  Printf.sprintf "%s leaves the inventory: this lane reads only what lives under %s"
    shown root
;;

let resolve_program ~base_path name =
  let root = programs_dir ~base_path in
  let trimmed = String.trim name in
  if trimmed = "" then Error "name a program"
  else if escapes trimmed then
    Error
      (Printf.sprintf "%S is not a name in the inventory: no paths, and no dots"
         trimmed)
  else if not (Sys.file_exists (Filename.concat root trimmed)) then
    Error (Printf.sprintf "no program named %S: put it under %s" trimmed root)
  else
    match within ~root (Filename.concat root trimmed) with
    | None -> Error (left_inventory ~root (Printf.sprintf "%S" trimmed))
    | Some path ->
      if Sys.is_directory path then
        (* Each mounted file is read once, here. Reading the executable again
           while building the mount list would let a replacement landing
           between the two reads give the guest one image to run and a
           different one to open. *)
        let read_one f =
          match within ~root (Filename.concat path f) with
          | Some real -> Ok (f, read_file real)
          | None -> Error (left_inventory ~root (trimmed ^ "/" ^ f))
        in
        let rec gather acc = function
          | [] -> Ok (List.rev acc)
          | f :: rest ->
            (match read_one f with
             | Error e -> Error e
             | Ok pair -> gather (pair :: acc) rest)
        in
        (match executable_in path with
         | Error e -> Error e
         | Ok (exe, others) ->
           (match read_one exe with
            | Error e -> Error e
            | Ok (_, exe_bytes) ->
              Result.map
                (fun mounted ->
                  (* entries_of sorts, so the mount list keeps the order the
                     inventory is listed in. *)
                  ( exe
                  , exe_bytes
                  , List.sort
                      (fun (a, _) (b, _) -> String.compare a b)
                      ((exe, exe_bytes) :: mounted) ))
                (gather [] others)))
      else begin
        (* One file boots alone, and is mounted under its own name too — a
           program that opens itself (overlays, self-reading installers)
           finds it. *)
        let bytes = read_file path in
        Ok (trimmed, bytes, [ (trimmed, bytes) ])
      end
;;

(* The board hears what happens on the shared machine, the way the MSX lane
   announces its arcade. A refused post does not fail the tool — the machine
   moved either way. *)
let relay_to_board ~author content =
  try
    let result =
      Board_tool_dispatch.handle_tool "masc_board_post"
        (`Assoc
          [ ("title", `String "DOS 아케이드")
          ; ("content", `String content)
          ; ("author", `String author)
          ; ("post_kind", `String "automation")
          ])
    in
    if not (Tool_result.is_success result) then
      Log.DosLog.warn "arcade relay: board post refused, the machine is unaffected: %s"
        (Tool_result.message result)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | e ->
    Log.DosLog.warn "arcade relay: board post raised, the machine is unaffected: %s"
      (Printexc.to_string e)
;;

let handle_load ~tool_name ~start_time ~base_path ~agent_name args =
  match get_string_opt args "program" with
  | None | Some "" ->
    (* No name: the inventory, so the next call can name a program. *)
    Tool_result.make_ok ~tool_name ~start_time
      ~data:
        (`Assoc
          [ ( "programs_available"
            , `List (List.map (fun n -> `String n) (programs_available ~base_path)) )
          ; ("programs_dir", `String (programs_dir ~base_path))
          ])
      ()
  | Some name ->
    (match resolve_program ~base_path name with
     | Error message -> reject ~tool_name ~start_time message
     | Ok (program_name, program_bytes, files) ->
       let loaded =
         Dos_lane.load ~ledger_dir:(dos_dir ~base_path) ~program_name ~program_bytes
           ~files
       in
       (match loaded with
        | Ok _ ->
          relay_to_board ~author:agent_name
            (Printf.sprintf "%s 님이 %s 을(를) 띄웠습니다" agent_name program_name)
        | Error _ -> ());
       of_lane_run ~tool_name ~start_time loaded)
;;

let handle_eject ~tool_name ~start_time ~agent_name _args =
  match Dos_lane.eject () with
  | Ok () ->
    relay_to_board ~author:agent_name
      (Printf.sprintf "%s 님이 기계를 껐습니다" agent_name);
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc [ ("ejected", `Bool true) ]) ()
  | Error e -> reject ~tool_name ~start_time (Dos_lane.error_to_string e)
;;

let handle_screen ~tool_name ~start_time _args =
  of_lane ~tool_name ~start_time (Dos_lane.screen ())
;;

let default_steps = 1_000_000

let handle_step ~tool_name ~start_time args =
  of_lane_run ~tool_name ~start_time
    (Dos_lane.step
       ~steps:(get_int args "steps" default_steps)
       ~until_ready:(get_bool args "until_ready" true))
;;

let handle_press ~tool_name ~start_time ~who args =
  of_lane_run ~tool_name ~start_time
    (Dos_lane.press ~who
       ~keys:(get_string_list args "keys")
       ~steps:(get_int args "steps" default_steps))
;;

let handle_type ~tool_name ~start_time ~who args =
  of_lane_run ~tool_name ~start_time
    (Dos_lane.type_text ~who ~text:(get_string args "text" "")
       ~steps:(get_int args "steps" default_steps))
;;

(* Addresses arrive as hex strings ("b8000", "0xB8000") because that is how
   memory is talked about; decimal parses too. *)
let parse_address s =
  let s = String.lowercase_ascii (String.trim s) in
  let s =
    if String.starts_with ~prefix:"0x" s then String.sub s 2 (String.length s - 2) else s
  in
  int_of_string_opt ("0x" ^ s)
;;

let handle_peek ~tool_name ~start_time args =
  let address =
    match parse_address (get_string args "address" "") with
    | Some a -> a
    | None -> -1
  in
  match Dos_lane.peek ~address ~length:(get_int args "length" 16) with
  | Ok hex ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:
        (`Assoc
          [ ("address", `String (Printf.sprintf "%05x" address)); ("hex", `String hex) ])
      ()
  | Error e -> reject ~tool_name ~start_time (Dos_lane.error_to_string e)
;;
