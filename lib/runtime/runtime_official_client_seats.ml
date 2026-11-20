module Slot_scheduler = Llm_provider.Slot_scheduler
module String_map = Map.Make (String)

type declaration =
  { runtime_id : string
  ; provider_id : string
  ; max_concurrent : int
  }

type disagreement =
  { account : string
  ; declarations : (string * int) list
  }

type published = int String_map.t

(* Accounts in the order they first appear. *)
let accounts (declarations : declaration list) =
  List.fold_left
    (fun seen (declaration : declaration) ->
       if List.exists (String.equal declaration.provider_id) seen
       then seen
       else declaration.provider_id :: seen)
    []
    declarations
  |> List.rev
;;

let declared_by account (declarations : declaration list) =
  List.filter_map
    (fun (declaration : declaration) ->
       if String.equal declaration.provider_id account
       then Some (declaration.runtime_id, declaration.max_concurrent)
       else None)
    declarations
;;

let of_declarations (declarations : declaration list) =
  let numbers =
    List.filter_map
      (fun account ->
         match declared_by account declarations with
         | [] -> None
         | ((_ : string), number) :: (_ : (string * int) list) as declared ->
           Some (account, number, declared))
      (accounts declarations)
  in
  let disagreements =
    List.filter_map
      (fun (account, number, declared) ->
         if List.for_all (fun ((_ : string), declared_number) -> Int.equal declared_number number) declared
         then None
         else Some { account; declarations = declared })
      numbers
  in
  match disagreements with
  | [] ->
    Ok
      (List.fold_left
         (fun published (account, number, (_ : (string * int) list)) ->
            String_map.add account number published)
         String_map.empty
         numbers)
  | _ :: _ -> Error disagreements
;;

type account_seats =
  { scheduler : Slot_scheduler.t
  ; number : int
  }

(* Read on every walk, written by a publish. A publish builds the whole next
   table under [publish_mutex] and swaps it in, so a reader sees one table or
   the other. *)
let published_seats : account_seats String_map.t Atomic.t = Atomic.make String_map.empty
let publish_mutex = Stdlib.Mutex.create ()

let publish (published : published) =
  Stdlib.Mutex.protect publish_mutex (fun () ->
    let next =
      String_map.fold
        (fun account number seats ->
           match String_map.find_opt account seats with
           | Some existing when Int.equal existing.number number -> seats
           | Some existing ->
             Slot_scheduler.reconfigure
               existing.scheduler
               ~max_slots:number
               ~priority_run_limit:None;
             String_map.add account { existing with number } seats
           | None ->
             String_map.add
               account
               { scheduler = Slot_scheduler.create ~max_slots:number ~priority_run_limit:None
               ; number
               }
               seats)
        published
        (Atomic.get published_seats)
    in
    Atomic.set published_seats next)
;;

let scheduler ~provider_id =
  Option.map
    (fun seats -> seats.scheduler)
    (String_map.find_opt provider_id (Atomic.get published_seats))
;;
