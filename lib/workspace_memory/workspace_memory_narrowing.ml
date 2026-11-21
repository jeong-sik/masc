module Ledger = Workspace_memory_ledger
module Request = Workspace_memory_request
module Fact_map = Ledger.Fact_map

module Fact_set = Set.Make (struct
    type t = Ledger.fact_ref

    let compare = Ledger.compare_fact_ref
  end)

module Slot_set = Set.Make (String)

type fact = Ledger.fact_ref
type slot = string

type generation =
  { lane : string
  ; requests : int
  }

type wake =
  | Commit
  | Tick

let combine_wake left right =
  match left, right with
  | Commit, Commit -> Commit
  | Tick, (Commit | Tick) | Commit, Tick -> Tick
;;

type chain =
  | Fresh
  | Sized_only
  | Other

type word =
  | Sized
  | Unsized
  | Unusable
  | Overdue
  | Quiet

let is_refusal = function
  | Sized | Unsized -> true
  | Unusable | Overdue | Quiet -> false
;;

let has_word = function
  | Sized | Unsized | Unusable | Overdue -> true
  | Quiet -> false
;;

(* A narrowing that saw only these words leaves the batch's size a fact the
   provider gave. *)
let keeps_size_fact = function
  | Sized | Quiet -> true
  | Unsized | Unusable | Overdue -> false
;;

(* Facts in pending order, oldest first, never empty: a batch in the list, a
   narrowed place, or one fact at the bottom. *)
type group =
  { members : fact list
  ; chain : chain
  }

(* [as_is]: asked with all its facts, not cut to the kept size. *)
type item =
  { group : group
  ; as_is : bool
  }

type memory =
  { generation : generation
  ; lane_slots : slot list
  ; places : group list
  ; refused : Slot_set.t Fact_map.t
  ; quiet : Fact_set.t
  ; kept_size : Request.size
  }

type pass =
  { started_on : generation
  ; pass_slots : slot list
  ; todo : item list
  }

type request =
  { facts : fact list
  ; size : Request.size
  ; slots : slot list
  }

type error =
  | No_item
  | Not_a_prefix_of_the_request

let error_to_string = function
  | No_item -> "the pass has no request out"
  | Not_a_prefix_of_the_request ->
    "the facts sent are empty or not the first facts of the pass's request"
;;

let empty generation ~slots =
  { generation
  ; lane_slots = slots
  ; places = []
  ; refused = Fact_map.empty
  ; quiet = Fact_set.empty
  ; kept_size = Request.Fill_frame
  }
;;

let restart memory ~requests =
  empty { memory.generation with requests } ~slots:memory.lane_slots
;;

let size memory = memory.kept_size

let refused_by memory fact slot =
  match Fact_map.find_opt fact memory.refused with
  | Some slots -> Slot_set.mem slot slots
  | None -> false
;;

let unrefused memory fact =
  List.filter (fun slot -> not (refused_by memory fact slot)) memory.lane_slots
;;

(* Model [Walked]: a one-fact request walks the slots that have not refused
   it. *)
let walked memory = function
  | [ fact ] -> unrefused memory fact
  | [] | _ :: _ :: _ -> memory.lane_slots
;;

(* Model [WaitingPlace]: a place waits for the tick unless it is one fact
   every slot refused. *)
let waits memory group =
  match group.members with
  | [ fact ] -> not (List.is_empty (unrefused memory fact))
  | _ :: _ :: _ -> true
  | [] -> false
;;

let set_aside memory =
  List.filter_map
    (fun group ->
       match group.members with
       | [ fact ] when List.is_empty (unrefused memory fact) -> Some fact
       | [ _ ] | [] | _ :: _ :: _ -> None)
    memory.places
;;

let waiting memory =
  (not (Fact_set.is_empty memory.quiet)) || List.exists (waits memory) memory.places
;;

let same_generation left right =
  String.equal left.lane right.lane && Int.equal left.requests right.requests
;;

let holds memory ~generation ~slots =
  same_generation memory.generation generation
  && List.equal String.equal memory.lane_slots slots
;;

let live memory pass = holds memory ~generation:pass.started_on ~slots:pass.pass_slots

let without gone places =
  List.filter
    (fun group -> not (List.exists (fun fact -> Fact_set.mem fact gone) group.members))
    places
;;

let fresh_item = function
  | [] -> []
  | _ :: _ as members -> [ { group = { members; chain = Fresh }; as_is = false } ]
;;

let start memory ~generation ~slots ~wake ~pending =
  let memory = if holds memory ~generation ~slots then memory else empty generation ~slots in
  let pending_set = Fact_set.of_list pending in
  let still fact = Fact_set.mem fact pending_set in
  let places =
    List.filter_map
      (fun group ->
         match List.filter still group.members with
         | [] -> None
         | _ :: _ as members -> Some { group with members })
      memory.places
  in
  let memory =
    { memory with
      places
    ; refused = Fact_map.filter (fun fact _ -> still fact) memory.refused
    ; quiet = Fact_set.filter still memory.quiet
    }
  in
  let placed =
    List.fold_left
      (fun set group -> List.fold_left (fun set fact -> Fact_set.add fact set) set group.members)
      Fact_set.empty
      places
  in
  let pass todo = { started_on = generation; pass_slots = slots; todo } in
  match wake with
  | Commit ->
    let fresh =
      List.filter
        (fun fact -> not (Fact_set.mem fact placed || Fact_set.mem fact memory.quiet))
        pending
    in
    memory, pass (fresh_item fresh)
  | Tick ->
    let pool = List.filter (fun fact -> not (Fact_set.mem fact placed)) pending in
    let by_first =
      List.fold_left
        (fun map group ->
           match group.members with
           | first :: _ when waits memory group -> Fact_map.add first group map
           | _ :: _ | [] -> map)
        Fact_map.empty
        places
    in
    let back =
      List.filter_map
        (fun fact ->
           Option.map (fun group -> { group; as_is = true }) (Fact_map.find_opt fact by_first))
        pending
    in
    { memory with quiet = Fact_set.empty }, pass (fresh_item pool @ back)
;;

let next memory pass =
  if not (live memory pass)
  then None
  else (
    match pass.todo with
    | [] -> None
    | item :: _ ->
      let size =
        if item.as_is then Request.Up_to (List.length item.group.members) else memory.kept_size
      in
      Some { facts = item.group.members; size; slots = walked memory item.group.members })
;;

let rec rest_after ~sent members =
  match sent, members with
  | [], rest -> Some rest
  | _ :: _, [] -> None
  | fact :: sent, member :: members ->
    if Ledger.compare_fact_ref fact member = 0 then rest_after ~sent members else None
;;

(* The batch asked and the list after it. Model [Cut], generalized: the
   frame or the kept size may have held only the first facts of the head;
   the rest stays next, made again rather than kept as it is. *)
let take pass ~sent =
  match pass.todo, sent with
  | [], _ -> Error No_item
  | _ :: _, [] -> Error Not_a_prefix_of_the_request
  | item :: later, _ :: _ ->
    (match rest_after ~sent item.group.members with
     | None -> Error Not_a_prefix_of_the_request
     | Some [] -> Ok (item.group, later)
     | Some (_ :: _ as rest) ->
       Ok
         ( { item.group with members = sent }
         , { group = { item.group with members = rest }; as_is = false } :: later ))
;;

let ended pass = { pass with todo = [] }

let answered memory pass ~sent =
  if not (live memory pass)
  then Ok (memory, ended pass)
  else
    Result.map
      (fun (asked, later) ->
         let gone = Fact_set.of_list asked.members in
         let kept_size =
           match asked.chain with
           | Sized_only -> Request.Up_to (List.length asked.members)
           | Fresh | Other -> memory.kept_size
         in
         ( { memory with
             places = without gone memory.places
           ; refused = Fact_map.filter (fun fact _ -> not (Fact_set.mem fact gone)) memory.refused
           ; quiet = Fact_set.diff memory.quiet gone
           ; kept_size
           }
         , { pass with todo = later } ))
      (take pass ~sent)
;;

let word_of heard slot =
  match List.find_opt (fun (said_by, _) -> String.equal said_by slot) heard with
  | Some (_, word) -> word
  | None -> Quiet
;;

(* Model [Narrow]: the older half next as it is, then the newer half made
   again on its own. *)
let narrow memory pass ~asked ~later ~words =
  let chain =
    match asked.chain with
    | Other -> Other
    | Fresh | Sized_only ->
      if List.for_all (fun (_, word) -> keeps_size_fact word) words then Sized_only else Other
  in
  let half = List.length asked.members / 2 in
  let older = { members = List.take half asked.members; chain } in
  let newer = { members = List.drop half asked.members; chain } in
  ( { memory with places = without (Fact_set.of_list asked.members) memory.places }
  , { pass with todo = { group = older; as_is = true } :: { group = newer; as_is = false } :: later }
  )
;;

(* Model [AllQuiet]: nothing is narrowed. A fresh batch leaves its facts
   waiting; a narrowed one is kept as it is. *)
let all_quiet memory pass ~asked ~later =
  let gone = Fact_set.of_list asked.members in
  match asked.chain with
  | Fresh -> { memory with quiet = Fact_set.union memory.quiet gone }, { pass with todo = later }
  | Sized_only | Other ->
    { memory with places = asked :: without gone memory.places }, { pass with todo = later }
;;

(* Model [Bottom]: the slots that refused the fact alone are kept, and it
   stays a place. A fresh fact that met only quiet slots leaves no mark. *)
let bottom memory pass ~fact ~asked ~later ~words =
  let spoke = List.exists (fun (_, word) -> has_word word) words in
  let alone =
    List.exists
      (fun group ->
         match group.members with
         | [ member ] -> Ledger.compare_fact_ref member fact = 0
         | [] | _ :: _ :: _ -> false)
      memory.places
  in
  let waits_unmarked =
    match asked.chain with
    | Fresh -> (not spoke) && not alone
    | Sized_only | Other -> false
  in
  if waits_unmarked
  then { memory with quiet = Fact_set.add fact memory.quiet }, { pass with todo = later }
  else (
    let marks =
      Slot_set.of_list
        (List.filter_map (fun (slot, word) -> if is_refusal word then Some slot else None) words)
    in
    let refused =
      if Slot_set.is_empty marks
      then memory.refused
      else
        Fact_map.update
          fact
          (function
            | None -> Some marks
            | Some known -> Some (Slot_set.union known marks))
          memory.refused
    in
    ( { memory with places = asked :: without (Fact_set.singleton fact) memory.places; refused }
    , { pass with todo = later } ))
;;

let unanswered memory pass ~sent ~heard =
  if not (live memory pass)
  then Ok (memory, ended pass)
  else
    Result.map
      (fun (asked, later) ->
         let words = List.map (fun slot -> slot, word_of heard slot) (walked memory asked.members) in
         match asked.members with
         | [] -> memory, { pass with todo = later }
         | [ fact ] -> bottom memory pass ~fact ~asked ~later ~words
         | _ :: _ :: _ ->
           if List.exists (fun (_, word) -> has_word word) words
           then narrow memory pass ~asked ~later ~words
           else all_quiet memory pass ~asked ~later)
      (take pass ~sent)
;;
