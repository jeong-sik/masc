(** See .mli for the contract. *)

type memory = int
type cpus = int

let mib_per_gib = 1024

(* The one suffix a size ends in, and how many MiB one of it is. *)
let memory_units = [ 'm', 1; 'M', 1; 'g', mib_per_gib; 'G', mib_per_gib ]

(* Digits only, at least one, without overflowing [int]. [int_of_string_opt]
   also takes a sign, underscores and 0x/0o/0b prefixes, none of which is a
   size an operator writes. *)
let decimal_digits raw =
  let length = String.length raw in
  let rec go index acc =
    if index = length
    then Some acc
    else (
      let digit = raw.[index] in
      if Char.compare digit '0' < 0 || Char.compare digit '9' > 0
      then None
      else (
        let value = Char.code digit - Char.code '0' in
        if acc > (max_int - value) / 10
        then None
        else go (index + 1) ((acc * 10) + value)))
  in
  if length = 0 then None else go 0 0
;;

let memory_form = "a whole number followed by m or g, e.g. \"8g\" or \"512m\""

let memory_of_string raw =
  let not_a_size =
    Error (Printf.sprintf "%S is not a guest memory size; expected %s" raw memory_form)
  in
  let length = String.length raw in
  if length < 2
  then not_a_size
  else (
    match
      ( List.assoc_opt raw.[length - 1] memory_units
      , decimal_digits (String.sub raw 0 (length - 1)) )
    with
    | None, (None | Some _) | Some _, None -> not_a_size
    | Some per_unit, Some count ->
      if count = 0
      then
        Error
          (Printf.sprintf
             "%S is not a guest memory size; expected more than zero, as %s"
             raw
             memory_form)
      else if count > max_int / per_unit
      then
        Error
          (Printf.sprintf
             "%S is too large to be a guest memory size; expected %s"
             raw
             memory_form)
      else Ok (count * per_unit))
;;

let memory_mib memory = memory
let memory_argv memory = Printf.sprintf "%dm" memory

let cpus_form = "a whole number of 1 or more, e.g. 4"

let cpus_of_int count =
  if count > 0
  then Ok count
  else Error (Printf.sprintf "%d is not a guest CPU count; expected %s" count cpus_form)
;;

(* Quotes the text as written, so "0" and " 4" are refused as themselves. *)
let cpus_of_string raw =
  match decimal_digits raw with
  | Some count when count > 0 -> Ok count
  | Some _ | None ->
    Error (Printf.sprintf "%S is not a guest CPU count; expected %s" raw cpus_form)
;;

let cpus_count cpus = cpus

type t =
  { memory : memory
  ; cpus : cpus
  }

let equal a b = Int.equal a.memory b.memory && Int.equal a.cpus b.cpus

let to_string size =
  Printf.sprintf "memory=%s cpus=%d" (memory_argv size.memory) size.cpus
;;

let resolve ~memory ~cpus ~default_memory ~default_cpus =
  let memory =
    match memory with
    | Some own -> Ok own
    | None -> default_memory ()
  in
  let cpus =
    match cpus with
    | Some own -> Ok own
    | None -> default_cpus ()
  in
  match memory, cpus with
  | Ok memory, Ok cpus -> Ok { memory; cpus }
  | Error detail, Ok _ | Ok _, Error detail -> Error detail
  | Error memory_detail, Error cpus_detail -> Error (memory_detail ^ "; " ^ cpus_detail)
;;
