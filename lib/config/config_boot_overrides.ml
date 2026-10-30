(** Process-local boot override store.

    Used for startup-loaded configuration that readers consult without
    mutating the real process environment.

    Precedence:
    - real process env, except for a file-owned name
    - boot override store
    - hardcoded default

    A file-owned name is one the runtime file is the only input for: the process
    environment is not read for it, so the shell that started the server cannot
    change what the file says.
*)

module StringMap = Set_util.StringMap
module StringSet = Set_util.StringSet

let table : string StringMap.t Atomic.t = Atomic.make StringMap.empty

let get_opt name =
  StringMap.find_opt name (Atomic.get table)

let set name value =
  let rec loop () =
    let current = Atomic.get table in
    let updated = StringMap.add name value current in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()

let clear name =
  let rec loop () =
    let current = Atomic.get table in
    let updated = StringMap.remove name current in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()

(* Declared once at boot by the runtime-file loader from the settings registry. *)
let file_owned : StringSet.t Atomic.t = Atomic.make StringSet.empty

let declare_file_owned names =
  Atomic.set file_owned (StringSet.of_list names)

let is_file_owned name =
  StringSet.mem name (Atomic.get file_owned)

let reset_for_tests () =
  Atomic.set table StringMap.empty;
  Atomic.set file_owned StringSet.empty

type source =
  | Env
  | Boot_override
  | Default

let source name =
  let boot_or_default () =
    match get_opt name with
    | Some _ -> Boot_override
    | None -> Default
  in
  if is_file_owned name then boot_or_default ()
  else
    match Sys.getenv_opt name with
    | Some _ -> Env
    | None -> boot_or_default ()

let source_to_string = function
  | Env -> "env"
  | Boot_override -> "boot_override"
  | Default -> "default"
