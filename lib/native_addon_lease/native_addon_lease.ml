type t = { instance_id : string; directories : string list }
type preparation = Unpublished | Current of t
type process = { instance_id : string; pid : int; started : string }
type status = Awaiting_exec | Live of process | Cleanup_pending of process | Settled
type error = Invalid_claim of string | Stale_claim | Consumed_claim
  | Busy of string | State_invalid of string | Io_failure of string
  | Identity_unavailable | Termination_refused of Owner_process_identity.error
let error_to_string = function
  | Invalid_claim detail | Busy detail | State_invalid detail | Io_failure detail -> detail
  | Stale_claim -> "native admission was replaced or retired"
  | Consumed_claim -> "native instance already consumed its execution admission"
  | Identity_unavailable -> "native process incarnation could not be observed"
  | Termination_refused _ -> "kernel-bound native termination was not confirmed"
let instance_id (t : t) = t.instance_id
let directories (t : t) = t.directories
let ( let* ) = Result.bind
external open_directory : string -> Unix.file_descr = "masc_native_lease_directory"
external open_private_file : Unix.file_descr -> string -> bool -> Unix.file_descr = "masc_native_lease_file"
external holder : Unix.file_descr -> int = "masc_native_lease_holder"
external leads_process_group : unit -> bool = "masc_native_lease_group_leader"
external replace_private_file : Unix.file_descr -> string -> string -> unit = "masc_native_lease_replace"
type slot = { directory : Unix.file_descr;
  lease : Unix.file_descr; intent : Unix.file_descr; owner : Unix.file_descr }
type intent = Admitted of string | Retired of string
type history_state = Reserved | Revoked | Consumed
type history = {state:history_state;cleanup_context:Yojson.Safe.t option}
let coordinator = Mutex.create ()
let protect work = try work () with
  | (Unix.Unix_error _ | Sys_error _) as exn -> Error (Io_failure (Printexc.to_string exn))
let close_all descriptors =
  let failure = List.fold_left (fun previous fd ->
    try Unix.close fd; previous with Unix.Unix_error _ as exn ->
      match previous with None -> Some exn | Some _ -> previous) None descriptors in
  match failure with None -> () | Some exn -> raise exn
let with_slots ?(create=false) directories work = protect (fun () -> Mutex.protect coordinator (fun () ->
  let opened = ref [] in
  let retain fd = opened := fd :: !opened;fd in
  Fun.protect ~finally:(fun () -> close_all !opened) (fun () ->
    let slots = List.map (fun path ->
      let directory = retain (open_directory path) in
      let file name = retain (open_private_file directory name create) in
      let gate = file "gate" in
      Unix.lockf gate Unix.F_LOCK 0;
      let slot = {directory;lease=file "lease";intent=file "intent.json";owner=file "owner.json"} in
      Unix.fsync directory;slot) directories in
    work slots)))
let read fd =
  ignore (Unix.lseek fd 0 Unix.SEEK_SET);
  let buffer = Bytes.create 4096 and output = Buffer.create 256 in
  let rec loop () = match Unix.read fd buffer 0 (Bytes.length buffer) with
    | 0 -> Buffer.contents output
    | size -> Buffer.add_subbytes output buffer 0 size;loop () in
  loop ()
let write_json slot fd value =
  let bytes = Bytes.of_string (Yojson.Safe.to_string value) in
  ignore (Unix.lseek fd 0 Unix.SEEK_SET);
  Unix.ftruncate fd 0;
  let rec loop offset = if offset < Bytes.length bytes then
    let written = Unix.write fd bytes offset (Bytes.length bytes-offset) in
    if written=0 then raise (Sys_error "native lease write made no progress") else loop (offset+written) in
  loop 0; Unix.fsync fd; Unix.fsync slot.directory
let decode_bytes decode = function
  | "" -> Ok None
  | bytes -> (try decode (Yojson.Safe.from_string bytes) |> Result.map Option.some
      with Yojson.Json_error detail -> Error (State_invalid detail))
let parse fd decode = Unix.fsync fd;decode_bytes decode (read fd)
let sorted = List.sort (fun (a,_) (b,_) -> String.compare a b)
let intent_of_json = function
  | `Assoc fields -> (match sorted fields with
      | ["instance_id",`String instance;"state",`String "admitted"] when String.trim instance<>"" -> Ok (Admitted instance)
      | ["instance_id",`String instance;"state",`String "retired"] when String.trim instance<>"" -> Ok (Retired instance)
      | _ -> Error (State_invalid "invalid native admission intent"))
  | _ -> Error (State_invalid "invalid native admission intent")
let read_intent slot = parse slot.intent intent_of_json
let owner_of_json = function
  | `Assoc fields -> (match sorted fields with
      | ["instance_id",`String instance_id;"pid",`Int pid;"started",`String started]
        when String.trim instance_id<>"" && pid>1 && String.trim started<>"" -> Ok {instance_id;pid;started}
      | _ -> Error (State_invalid "invalid native process receipt"))
  | _ -> Error (State_invalid "invalid native process receipt")
let read_owner slot = parse slot.owner owner_of_json
let write_metadata slot name value =
  replace_private_file slot.directory name (Yojson.Safe.to_string value)
let write_intent slot instance state = write_metadata slot "intent.json"
  (`Assoc ["instance_id",`String instance;"state",`String state])
let history_name instance =
  "instance-" ^ Digestif.SHA256.(to_hex (digest_string instance)) ^ ".json"
let with_history slot instance work =
  let fd = open_private_file slot.directory (history_name instance) false in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> work fd)
let history_of_json instance = function
  | `Assoc fields -> (match sorted fields with
      | ["cleanup_context",context;"instance_id",`String known;"state",`String state;"version",`Int 2] when known=instance ->
          let* state=match state with
            | "reserved" -> Ok Reserved | "revoked" -> Ok Revoked | "consumed" -> Ok Consumed
            | _ -> Error (State_invalid "invalid native instance history") in
          let cleanup_context=match context with `Null -> None | value -> Some value in
          Ok {state;cleanup_context}
      | _ -> Error (State_invalid "invalid native instance history"))
  | _ -> Error (State_invalid "invalid native instance history")
let present_history = function
  | Some history -> Ok history
  | None -> Error (State_invalid "native instance history is empty")
let read_history fd instance =
  let* history = parse fd (history_of_json instance) in
  present_history history
let write_history slot instance history =
  let state = match history.state with Reserved -> "reserved" | Revoked -> "revoked" | Consumed -> "consumed" in
  write_metadata slot (history_name instance) (`Assoc ["instance_id",`String instance;"state",`String state;
    "cleanup_context",Option.value ~default:`Null history.cleanup_context;"version",`Int 2])
let unused_instance slot instance =
  try with_history slot instance (fun fd ->
  let* history = read_history fd instance in
  match history.state with
  | Consumed -> Error Consumed_claim
  | Reserved | Revoked -> Error Stale_claim)
  with Unix.Unix_error (Unix.ENOENT,_,_) -> Ok ()
let reserved_instance slot instance = with_history slot instance (fun fd ->
  let* history = read_history fd instance in
  match history.state with
  | Reserved -> Ok ()
  | Consumed -> Error Consumed_claim
  | Revoked -> Error Stale_claim)
let original_alive process =
  try Unix.kill process.pid 0;
    match Posix_spawn_detached.process_start process.pid with
    | Some started -> Ok (String.equal started process.started)
    | None -> Error Identity_unavailable
  with Unix.Unix_error (Unix.ESRCH,_,_) -> Ok false
let cleared process =
  let* alive = original_alive process in
  Ok (not alive && not (Posix_spawn_detached.group_id_has_members process.pid))
let predecessor_clear slot =
  if holder slot.lease <> 0 then Error (Busy "native claim has a kernel lease holder")
  else let* previous = read_owner slot in
    match previous with
    | None -> Ok ()
    | Some previous -> let* gone = cleared previous in
        if gone then Ok () else Error (Busy "native predecessor or foreground group is not released")
let rec sync_ancestry path =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
  let parent = Filename.dirname path in
  if parent<>path then sync_ancestry parent
let canonical_directories ~sync_ancestry ~create directories =
  if directories=[] || List.exists (fun path -> Filename.is_relative path || String.contains path '\000') directories then
    Error (Invalid_claim "native claims require absolute private directories")
  else protect (fun () ->
    if create then List.iter (fun path ->
      try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST,_,_) -> ()) directories;
    let directories = List.map (fun path ->
      let directory = open_directory path in
      Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
        let canonical = Unix.realpath path in
        Unix.fsync directory;sync_ancestry (Filename.dirname canonical);canonical)) directories in
    Ok (List.sort_uniq String.compare directories))
let claim ?(sync_ancestry=sync_ancestry) ~create ~instance_id ~directories () =
  if String.trim instance_id="" || String.contains instance_id '\000' then Error (Invalid_claim "native instance must be nonblank without NUL")
  else let* directories = canonical_directories ~sync_ancestry ~create directories in
    Ok {instance_id;directories}
let traverse f = List.fold_left (fun result slot -> let* () = result in f slot) (Ok ())
let prepare_with_sync ~sync_ancestry ~directories ~instance_id ~cleanup_context =
  let* t = claim ~sync_ancestry ~create:true ~instance_id ~directories () in
  let* () = with_slots ~create:true t.directories (fun slots ->
      let* () = traverse (fun slot ->
        let* () = predecessor_clear slot in
        let* _intent = read_intent slot in
        unused_instance slot instance_id) slots in
      (* Reserve before publishing the current intent. Never erase these files:
         latest-owner receipts alone forget A when B replaces it. *)
      List.iter (fun slot -> write_history slot instance_id {state=Reserved;cleanup_context}) slots;
      List.iter (fun slot -> write_intent slot instance_id "admitted") slots;Ok ()) in
  Ok t
let prepare = prepare_with_sync ~sync_ancestry
let check_current (t : t) slot =
  let* intent = read_intent slot in
  match intent with
  | Some (Admitted instance) when instance=t.instance_id -> Ok false
  | Some (Retired instance) when instance=t.instance_id -> Ok true
  | None | Some (Admitted _ | Retired _) -> Error Stale_claim
let existing_context t slots =
  let* contexts=List.fold_left (fun result slot -> let* contexts=result in
    let* _retired=check_current t slot in
    with_history slot t.instance_id (fun fd -> let* history=read_history fd t.instance_id in
      Ok (history.cleanup_context::contexts))) (Ok []) slots in
  match contexts with
  | [] -> Error (Invalid_claim "native claim has no resource context")
  | context::rest -> if List.for_all ((=) context) rest then Ok context
      else Error (State_invalid "native cleanup contexts disagree")
let validate_existing t slots = existing_context t slots |> Result.map ignore
let reopen ~directories ~instance_id =
  let* t = claim ~create:false ~instance_id ~directories () in
  let* () = with_slots t.directories (validate_existing t) in Ok t
let current ~directories =
  let* directories = canonical_directories ~sync_ancestry ~create:false directories in
  with_slots directories (fun slots ->
    match slots with
    | [] -> Error (Invalid_claim "native claim has no slots")
    | slot::_ ->
        let* intent = read_intent slot in
        let* instance_id = match intent with
          | Some (Admitted id | Retired id) -> Ok id
          | None -> Error (State_invalid "current native intent is missing") in
        let t = {directories;instance_id} in
        let* () = validate_existing t slots in Ok t)
let temporary_metadata name = match String.split_on_char '-' name with
  | [".pending";pid;sequence] ->
      (match int_of_string_opt pid, int_of_string_opt sequence with
       | Some pid, Some sequence -> pid > 0 && sequence > 0
       | None, (Some _ | None) | Some _, None -> false)
  | [] | [_] | [_;_] | [_;_;_] | _::_::_::_ -> false
(* The files of a slot that are not an instance history. *)
let slot_files = ["gate";"lease";"intent.json";"owner.json"]
let history_instance name = function
  | `Assoc fields -> (match List.assoc_opt "instance_id" fields with
      | Some (`String instance) when name=history_name instance -> Ok instance
      | None | Some _ -> Error (State_invalid "unknown native preparation metadata"))
  | _ -> Error (State_invalid "unknown native preparation metadata")
let preparation_histories path directory =
  Array.fold_left (fun result name ->
    let* histories = result in
    if List.mem name slot_files then Ok histories
    else
      let fd = open_private_file directory name false in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        (* Staged metadata is never an authority name and cannot admit a
           launcher. Keep it for diagnosis after an interrupted atomic write. *)
        if temporary_metadata name then Ok histories
        else
          let* instance = parse fd (history_instance name) in
          match instance with
          | None -> Error (State_invalid "native preparation history is empty")
          | Some instance ->
              let* history = read_history fd instance in Ok ((instance,history)::histories)))
    (Ok []) (Sys.readdir path)
let recover_preparation ~directory:path =
  let* directories = canonical_directories ~sync_ancestry ~create:false [path] in
  protect (fun () ->
    let directory = open_directory path in
    let* may_complete = Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
      let contents name =
        try
          let fd = open_private_file directory name false in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Ok (Some (read fd)))
        with Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None in
      let* intent = contents "intent.json" in
      let* owner = contents "owner.json" in
      match intent, owner with
      | Some text, _ when text<>"" -> Ok false
      | _, Some text when text<>"" -> Ok false
      | (None | Some _), (None | Some _) ->
          let* histories = preparation_histories path directory in
          if List.exists (fun (_,history) -> match history.state with
              | Reserved | Revoked -> false | Consumed -> true) histories then Ok false
          else match histories with
            | [] | [_] -> Ok true
            | _::_::_ -> Error (State_invalid "unpublished native reservations disagree")) in
    with_slots ~create:may_complete directories (function
      | [slot] ->
          let* intent = read_intent slot in
          (match intent with
           | Some (Admitted instance_id | Retired instance_id) ->
               let claim={directories;instance_id} in
               let* ()=validate_existing claim [slot] in Ok (Current claim)
           | None when not may_complete -> Error (State_invalid "current native intent is missing")
           | None ->
               let* ()=predecessor_clear slot in
               let* owner=read_owner slot in
               (match owner with
                | Some _ -> Error (State_invalid "unpublished slot has a native owner")
                | None ->
                    let* histories=preparation_histories path slot.directory in
                    match histories with
                    | [] -> Ok Unpublished
                    | [instance_id,history] ->
                        (match history.state with
                         | Consumed -> Error (State_invalid "native preparation was already consumed")
                         | Reserved | Revoked ->
                             (* Recover cleanup authority, never execution. The
                                original ID remains permanently unavailable. *)
                             write_history slot instance_id {history with state=Revoked};
                             write_intent slot instance_id "retired";
                             Ok (Current {directories;instance_id}))
                    | _::_::_ -> Error (State_invalid "unpublished native reservations disagree")))
      | [] | _::_::_ -> Error (Invalid_claim "native preparation requires one installation slot")))
let cleanup_context t = with_slots t.directories (existing_context t)
type recorded = { instance : string; history : string; context : Yojson.Safe.t option }
type inspection_error = { refusal : string; refused_instance : string option }
(* The bytes of one slot file, [None] when it does not exist. *)
let peek path =
  match Unix.openfile path [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 with
  | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None
  | fd -> Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Ok (Some (read fd)))
(* The reads [reopen], [current] and [recover_preparation] make, without the
   gate, the coordinator, fsync or [create]: a deploy check reads the slots of a
   server that may still be running and must never wait on or change them.
   Intents and histories are replaced by rename, so each read sees one whole
   version. The owner receipt is written in place once, by the launcher before
   it execs, so a read during that write can refuse once; a second run reads it
   whole. *)
let inspect ~directory =
  let path name = Filename.concat directory name in
  let refuse ?instance name error =
    Error { refusal = path name ^ ": " ^ error_to_string error; refused_instance = instance } in
  let decode ?missing ?instance name decoder =
    match protect (fun () ->
      let* bytes = peek (path name) in
      match bytes, missing with
      | None, None -> Ok None
      | None, Some error -> Error error
      | Some bytes, (None | Some _) -> decode_bytes decoder bytes) with
    | Ok value -> Ok value
    | Error error -> refuse ?instance name error in
  let history instance =
    let name = history_name instance in
    let* history = decode ~instance name (history_of_json instance)
        ~missing:(State_invalid "native instance history is missing") in
    match history with
    | None -> refuse ~instance name (State_invalid "native instance history is empty")
    | Some history -> Ok (history, {instance; history=name; context=history.cleanup_context}) in
  let* intent = decode "intent.json" intent_of_json in
  let current = match intent with
    | Some (Admitted instance | Retired instance) -> Some instance
    | None -> None in
  let* owner = decode ?instance:current "owner.json" owner_of_json in
  match current with
  | Some instance ->
      (* [with_slots] opens every slot file and creates none of them here. *)
      let* () = List.fold_left (fun result name ->
        let* () = result in
        match Unix.lstat (path name) with
        | _ -> Ok ()
        | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
            refuse ~instance name (State_invalid "native slot file is missing")
        | exception Unix.Unix_error (code,_,_) ->
            refuse ~instance name (Io_failure (Unix.error_message code))) (Ok ()) slot_files in
      let* _, recorded = history instance in
      Ok (Some recorded)
  | None ->
      match owner with
      | Some _ -> refuse "intent.json" (State_invalid "current native intent is missing")
      | None ->
          let* names = match protect (fun () -> Ok (Sys.readdir directory)) with
            | Ok names -> Ok names
            | Error error -> Error { refusal = directory ^ ": " ^ error_to_string error; refused_instance = None } in
          let* histories = Array.fold_left (fun result name ->
            let* histories = result in
            if List.mem name slot_files || temporary_metadata name then Ok histories
            else
              let* instance = decode name (history_instance name) in
              match instance with
              | None -> refuse name (State_invalid "native preparation history is empty")
              | Some instance -> let* found = history instance in Ok (found::histories))
            (Ok []) names in
          match histories with
          | [] -> Ok None
          | [{state=Consumed;_}, recorded] ->
              refuse ~instance:recorded.instance recorded.history
                (State_invalid "native preparation was already consumed")
          | [{state=(Reserved | Revoked);_}, recorded] -> Ok (Some recorded)
          | _::_::_ ->
              Error { refusal = directory ^ ": unpublished native reservations disagree"; refused_instance = None }
let retire t = with_slots t.directories (fun slots ->
  let* () = traverse (fun slot -> check_current t slot |> Result.map ignore) slots in
  let* () = traverse (fun slot -> with_history slot t.instance_id (fun fd ->
    let* history = read_history fd t.instance_id in
    match history.state with
    | Reserved -> write_history slot t.instance_id {history with state=Revoked}; Ok ()
    | Revoked | Consumed -> Ok ())) slots in
  List.iter (fun slot -> write_intent slot t.instance_id "retired") slots;Ok ())
let slot_status t slot =
  let* retired = check_current t slot in
  let* owner = read_owner slot in
  let pid = holder slot.lease in
  match owner with
  | Some owner when owner.instance_id=t.instance_id ->
      if pid=owner.pid then
        let* alive = original_alive owner in
        if alive then Ok (Live owner) else Error (State_invalid "kernel lease holder has a different process incarnation")
      else if pid<>0 then Error (State_invalid "native receipt differs from kernel lease holder")
      else let* gone = cleared owner in
        if gone then Ok (if retired then Settled else Cleanup_pending owner)
        else Ok (Cleanup_pending owner)
  | None | Some _ ->
      let* () = predecessor_clear slot in
      Ok (if retired then Settled else Awaiting_exec)
let statuses t slots = List.fold_left (fun result slot -> let* values = result in
  let* value = slot_status t slot in Ok (value::values)) (Ok []) slots
let status t = with_slots t.directories (fun slots ->
  let* values = statuses t slots in
  let live = List.filter_map (function Live p -> Some p | Awaiting_exec | Cleanup_pending _ | Settled -> None) values in
  match live with
  | first::rest ->
      if List.for_all (fun p -> p.pid=first.pid && p.started=first.started) rest then Ok (Live first)
      else Error (State_invalid "native resource holders disagree")
  | [] ->
      match List.find_opt (function Cleanup_pending _ -> true | Awaiting_exec | Live _ | Settled -> false) values with
      | Some (Cleanup_pending p) -> Ok (Cleanup_pending p)
      | None | Some (Awaiting_exec | Live _ | Settled) ->
          if List.exists (function Awaiting_exec -> true | Live _ | Cleanup_pending _ | Settled -> false) values
          then Ok Awaiting_exec else Ok Settled)
let request_termination t =
  let* () = retire t in
  let* identities = with_slots t.directories (fun slots ->
    let captured = ref [] and transferred = ref false in
    Fun.protect ~finally:(fun () ->
      if not !transferred then List.iter Owner_process_identity.close !captured) (fun () ->
    let result = traverse (fun slot ->
      let* state = slot_status t slot in
      match state with
      | Awaiting_exec -> Error (State_invalid "retired native claim still awaits execution")
      | Settled | Cleanup_pending _ -> Ok ()
      | Live process ->
          let* identity = Owner_process_identity.capture ~lease_fd:slot.lease
            |> Result.map_error (fun error -> Termination_refused error) in
          captured := identity :: !captured;
          if holder slot.lease=process.pid then Ok () else Error Stale_claim) slots in
    match result with
    | Ok () -> transferred := true; Ok !captured
    | Error error -> Error error)) in
  Fun.protect ~finally:(fun () -> List.iter Owner_process_identity.close identities) (fun () ->
    List.fold_left (fun result identity -> let* () = result in
      Owner_process_identity.request_termination identity
      |> Result.map_error (fun error -> Termination_refused error)) (Ok ()) identities)
let exec ~instance_id ~directories ~command ~arguments =
  let* t = claim ~create:false ~instance_id ~directories () in
  if String.trim command="" || List.exists (fun text -> String.contains text '\000') (command::arguments) then
    Error (Invalid_claim "native command must be nonblank without NUL")
  else if not (leads_process_group ()) then Error (Invalid_claim "native launcher must lead its foreground process group")
  else with_slots t.directories (fun slots ->
    let* () = validate_existing t slots in
    let* () = traverse (fun slot ->
      let* retired = check_current t slot in
      if retired then Error Stale_claim else
      let* () = predecessor_clear slot in
      reserved_instance slot instance_id) slots in
    let* started = Option.to_result ~none:Identity_unavailable (Posix_spawn_detached.process_start (Unix.getpid ())) in
    List.iter (fun slot -> Unix.lockf slot.lease Unix.F_TLOCK 0) slots;
    let* ()=traverse (fun slot -> with_history slot instance_id (fun fd ->
      let* history=read_history fd instance_id in
      write_history slot instance_id {history with state=Consumed};Ok ())) slots in
    List.iter (fun slot -> write_json slot slot.owner
      (`Assoc ["instance_id",`String instance_id;"pid",`Int (Unix.getpid ());"started",`String started])) slots;
    (* Closing ANY descriptor for a POSIX lease inode drops that process's lock.
       Keep only the exact lease descriptor through exec; gates/metadata close. *)
    List.iter (fun slot -> Unix.clear_close_on_exec slot.lease) slots;
    Unix.execvpe command (Array.of_list (command::arguments)) (Unix.environment ()))
module For_testing = struct
  let prepare = prepare_with_sync
end
