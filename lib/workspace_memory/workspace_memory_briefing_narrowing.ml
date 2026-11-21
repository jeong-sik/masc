module Briefing = Workspace_memory_briefing
module Narrowing = Workspace_memory_narrowing

type slot = string

type word =
  | Refused
  | Output_limit
  | Unusable
  | Overdue
  | Quiet

(* The request the briefing waits at, and the slots that refused it. *)
type hold =
  { keys : Briefing.key list
  ; refused : slot list
  }

type memory =
  { generation : Narrowing.generation
  ; slots : slot list
  ; hold : hold option
  }

let empty generation ~slots = { generation; slots; hold = None }

let restart memory ~requests =
  { memory with
    generation = { memory.generation with Narrowing.requests = requests }
  ; hold = None
  }
;;

let forget memory = { memory with hold = None }

let same_generation (left : Narrowing.generation) (right : Narrowing.generation) =
  String.equal left.lane right.lane && Int.equal left.requests right.requests
;;

let rec is_prefix prefix keys =
  match prefix, keys with
  | [], _ -> true
  | _ :: _, [] -> false
  | key :: prefix, first :: keys -> Briefing.equal_key key first && is_prefix prefix keys
;;

let stands memory hold = List.for_all (fun slot -> List.mem slot hold.refused) memory.slots

type start =
  | Ask of
      { count : int
      ; slots : slot list
      }
  | Wait
  | Stand

let start memory ~generation ~slots ~wake ~keys =
  let memory =
    if same_generation memory.generation generation && List.equal String.equal memory.slots slots
    then memory
    else empty generation ~slots
  in
  match memory.hold with
  | Some hold when is_prefix hold.keys keys ->
    if stands memory hold
    then memory, Stand
    else (
      match wake with
      | Narrowing.Commit -> memory, Wait
      | Narrowing.Tick ->
        ( memory
        , Ask
            { count = List.length hold.keys
            ; slots = List.filter (fun slot -> not (List.mem slot hold.refused)) slots
            } ))
  | Some _ | None -> { memory with hold = None }, Ask { count = List.length keys; slots }
;;

type unanswered =
  | Narrow
  | Waits
  | Stands
  | Moved

type error = No_entry

let error_to_string = function
  | No_entry -> "the briefing request held no entry"
;;

(* A word that narrows a request of two entries or more (RFC §4.1 c, §4.5). *)
let narrows = function
  | Refused | Unusable | Overdue -> true
  | Output_limit | Quiet -> false
;;

(* A word after which the slot is not asked the same request again. *)
let refuses = function
  | Refused | Output_limit -> true
  | Unusable | Overdue | Quiet -> false
;;

let unanswered memory ~generation ~sent ~heard =
  match sent with
  | [] -> Error No_entry
  | _ :: _ when not (same_generation memory.generation generation) -> Ok (memory, Moved)
  | _ :: _ :: _ when List.exists (fun (_, word) -> narrows word) heard ->
    Ok ({ memory with hold = None }, Narrow)
  | _ :: _ ->
    let before =
      match memory.hold with
      | Some hold when List.equal Briefing.equal_key hold.keys sent -> hold.refused
      | Some _ | None -> []
    in
    let refused =
      List.fold_left
        (fun refused (slot, word) ->
           if refuses word && not (List.mem slot refused) then refused @ [ slot ] else refused)
        before
        heard
    in
    let hold = { keys = sent; refused } in
    Ok ({ memory with hold = Some hold }, if stands memory hold then Stands else Waits)
;;

let answered memory ~generation =
  if same_generation memory.generation generation then { memory with hold = None } else memory
;;
