(** Process-local boot override store.

    Used for startup-loaded configuration defaults that should behave like env
    inputs for readers, without mutating the real process environment.

    Precedence remains:
    - real process env
    - boot override store
    - hardcoded default
*)

module StringMap = Map.Make (String)

let table : string StringMap.t Atomic.t = Atomic.make StringMap.empty
let get_opt name = StringMap.find_opt name (Atomic.get table)

let set name value =
  let rec loop () =
    let current = Atomic.get table in
    let updated = StringMap.add name value current in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()
;;

let clear name =
  let rec loop () =
    let current = Atomic.get table in
    let updated = StringMap.remove name current in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()
;;

let reset_for_tests () = Atomic.set table StringMap.empty

let source name =
  match Sys.getenv_opt name with
  | Some _ -> "env"
  | None ->
    (match get_opt name with
     | Some _ -> "boot_override"
     | None -> "default")
;;
