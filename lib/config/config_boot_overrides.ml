(** Process-local typed boot configuration store.

    Stores typed values decoded directly from [runtime.toml] instead of
    serializing TOML scalars into fake environment strings for readers to
    re-parse.

    Precedence:
    - real process env, except for a file-owned name
    - typed boot configuration store
    - hardcoded default *)

module StringMap = Set_util.StringMap
module StringSet = Set_util.StringSet

type typed_value =
  | Bool of bool
  | Int of int
  | Float of float
  | String of string

let display_float value =
  let rec find precision =
    let text = Printf.sprintf "%.*g" precision value in
    if precision = 17
       || Option.fold ~none:false ~some:(Float.equal value) (float_of_string_opt text)
    then text
    else find (precision + 1)
  in
  find 6
;;

let typed_value_to_string = function
  | Bool b -> if b then "true" else "false"
  | Int i -> string_of_int i
  | Float f -> display_float f
  | String s -> s
;;

let table : typed_value StringMap.t Atomic.t = Atomic.make StringMap.empty

let get_typed_opt name =
  StringMap.find_opt name (Atomic.get table)
;;

let get_opt name =
  Option.map typed_value_to_string (get_typed_opt name)
;;

let set_typed name value =
  let rec loop () =
    let current = Atomic.get table in
    let updated = StringMap.add name value current in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()
;;

let set_typed_batch pairs =
  let rec loop () =
    let current = Atomic.get table in
    let updated =
      List.fold_left (fun acc (name, value) -> StringMap.add name value acc) current pairs
    in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()
;;

let set name value = set_typed name (String value)

let clear name =
  let rec loop () =
    let current = Atomic.get table in
    let updated = StringMap.remove name current in
    if not (Atomic.compare_and_set table current updated) then loop ()
  in
  loop ()
;;

(* Declared once at boot by the runtime-file loader from the settings registry. *)
let file_owned : StringSet.t Atomic.t = Atomic.make StringSet.empty

let declare_file_owned names =
  Atomic.set file_owned (StringSet.of_list names)
;;

let is_file_owned name =
  StringSet.mem name (Atomic.get file_owned)
;;

let reset_for_tests () =
  Atomic.set table StringMap.empty;
  Atomic.set file_owned StringSet.empty
;;

type source =
  | Env
  | Boot_override
  | Default

let source name =
  let boot_or_default () =
    match get_typed_opt name with
    | Some _ -> Boot_override
    | None -> Default
  in
  if is_file_owned name then boot_or_default ()
  else
    match Sys.getenv_opt name with
    | Some _ -> Env
    | None -> boot_or_default ()
;;
