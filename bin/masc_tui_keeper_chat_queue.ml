type t = (string * string) list  (* oldest first *)

let empty = []
let is_empty = function [] -> true | _ :: _ -> false
let length = List.length
let waiting queue = queue
let cap = 32

let push queue ~keeper_name text =
  if List.length queue >= cap
  then
    Error
      (Printf.sprintf
         "%d messages are already waiting for the current turn; this one was \
          not queued and is still in the composer"
         cap)
  else (
    let queue = queue @ [ (keeper_name, text) ] in
    Ok (queue, List.length queue))
;;

let take_first_sendable queue ~sendable =
  let rec walk skipped = function
    | [] -> None
    | ((keeper_name, _) as entry) :: rest when sendable keeper_name ->
      Some (entry, List.rev_append skipped rest)
    | entry :: rest -> walk (entry :: skipped) rest
  in
  walk [] queue
;;

let take_newest queue =
  match List.rev queue with
  | [] -> None
  | newest :: reversed_rest -> Some (newest, List.rev reversed_rest)
;;

let drop_for_keeper queue ~keeper_name =
  List.filter (fun (queued, _) -> not (String.equal queued keeper_name)) queue
;;
