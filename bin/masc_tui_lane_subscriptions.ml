module Subscription = Masc.Lane_addon_subscription
type target = { installation_id:string; run_id:string; output_id:string; instance_id:string; title:string }
type reader_state = Unavailable of string | Position of {instance_id:string; acknowledged:int; latest:int; replaced:bool}
type snapshot = {revision:string option; entries:(Subscription.subscription * reader_state) list}
type request = Inspect | Save of {revision:string option; subscriptions:Subscription.subscription list}
type phase = Browse of int | Keeper of int | Output of string * int
  | Confirm_add of string * target | Confirm_remove of Subscription.subscription
type t = {keepers:string list; targets:target list; snapshot:snapshot option; phase:phase; error:string option}
let initial ~keepers ~targets = {keepers=List.sort_uniq String.compare keepers;targets;
  snapshot=None;phase=Browse 0;error=None}
let ( let* ) = Result.bind
let field key = function `Assoc fields -> (match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error ("missing subscription " ^ key))
  | _ -> Error "expected subscription object"
let text = function `String value when String.trim value<>"" -> Ok value | _ -> Error "expected subscription text"
let number = function `Int value when value>=0 -> Ok value | _ -> Error "expected nonnegative sequence"
let boolean = function `Bool value -> Ok value | _ -> Error "expected subscription boolean"
let get key parse value = let* value=field key value in parse value
let rec array parse = function
  | `List [] -> Ok []
  | `List (head::tail) -> let* head=parse head in let* tail=array parse (`List tail) in Ok (head::tail)
  | _ -> Error "expected subscription list"
let decode value =
  let* revision = get "source_revision" (function `Null -> Ok None | value ->
    let* value=text value in Ok (Some value)) value in
  let* subscriptions=get "subscriptions" (array Subscription.decode) value in
  let* states=get "reader_states" (array (fun entry ->
    let* subscription=get "subscription" Subscription.decode entry in
    let* state = match entry with
      | `Assoc fields when List.mem_assoc "unavailable" fields ->
          let* detail=get "unavailable" text entry in Ok (Unavailable detail)
      | _ ->
          let* instance_id=get "instance_id" text entry in
          let* acknowledged=get "after_sequence" number entry in
          let* latest=get "latest_sequence" number entry in
          let* replaced=get "replaced" boolean entry in
          let* unread=get "new_observations" boolean entry in
          if acknowledged>latest || unread<>(latest>acknowledged)
          then Error "inconsistent subscription position"
          else Ok (Position {instance_id;acknowledged;latest;replaced}) in
    Ok (subscription,state))) value in
  if List.sort Stdlib.compare subscriptions<>List.sort Stdlib.compare (List.map fst states)
    || List.length subscriptions<>List.length (List.sort_uniq Stdlib.compare subscriptions)
  then Error "subscription reader states do not match configuration"
  else Ok {revision;entries=states}
let request_json = function
  | Inspect -> `Assoc ["operation",`String "inspect"]
  | Save {revision;subscriptions} -> `Assoc
      (["operation",`String "save";"subscriptions",`List (List.map Subscription.json subscriptions)]
       @ match revision with None->[]|Some value->["expected_source_revision",`String value])
let loaded t = function
  | Error detail -> {t with error=Some detail}
  | Ok snapshot -> {t with snapshot=Some snapshot;phase=Browse 0;error=None}
let entries t = match t.snapshot with None->[]|Some snapshot->snapshot.entries
let at values cursor = List.nth_opt values cursor
let move t delta =
  let advance index count = max 0 (min (count-1) (index+delta)) in
  {t with phase=(match t.phase with
    | Browse index -> Browse (advance index (List.length (entries t)))
    | Keeper index -> Keeper (advance index (List.length t.keepers))
    | Output (keeper,index) -> Output (keeper,advance index (List.length t.targets))
    | Confirm_add _ | Confirm_remove _ -> t.phase)}
let add t = match t.snapshot,t.keepers,t.targets with
  | None,_,_ -> {t with error=Some "Read subscription configuration before editing."}
  | _,[],_ -> {t with error=Some "No workspace Keeper is available in the roster. Close and refresh."}
  | _,_,[] -> {t with error=Some "No current declared installation exposes a named output. Close and refresh."}
  | _ -> {t with phase=Keeper 0;error=None}
let remove t = match t.phase with
  | Browse index -> (match at (entries t) index with
      | Some (subscription,_) -> {t with phase=Confirm_remove subscription;error=None}
      | None -> {t with error=Some "No subscription selected."})
  | _ -> t
let back t = match t.phase with
  | Browse _ -> None
  | Keeper _ -> Some {t with phase=Browse 0;error=None}
  | Output _ -> Some {t with phase=Keeper 0;error=None}
  | Confirm_add (keeper,_) -> Some {t with phase=Output (keeper,0);error=None}
  | Confirm_remove _ -> Some {t with phase=Browse 0;error=None}
let subscription keeper (target:target) : Subscription.subscription =
  {keeper_name=keeper;run_id=target.run_id;installation_id=target.installation_id;output_id=target.output_id}
let enter ~keepers ~targets t =
  let refuse detail = {t with error=Some detail},None in
  let save subscriptions = match t.snapshot with
    | None -> refuse "Subscription configuration is unavailable."
    | Some snapshot -> t,Some (Save {revision=snapshot.revision;subscriptions}) in
  match t.phase with
  | Browse _ -> t,None
  | Keeper index -> (match at t.keepers index with
      | Some keeper -> {t with phase=Output (keeper,0);error=None},None
      | None -> refuse "No Keeper selected.")
  | Output (keeper,index) -> (match at t.targets index with
      | Some target -> {t with phase=Confirm_add (keeper,target);error=None},None
      | None -> refuse "No output selected.")
  | Confirm_add (keeper,target) ->
      if not (List.mem keeper keepers && List.mem target targets)
      then refuse "Keeper or output changed. Close and refresh before choosing again."
      else let chosen=subscription keeper target in
        if List.exists (fun (existing,_) -> existing=chosen) (entries t)
        then refuse "This Keeper already subscribes to that output."
        else save (List.map fst (entries t) @ [chosen])
  | Confirm_remove chosen -> save (List.map fst (entries t) |> List.filter (fun entry -> entry<>chosen))
let identity (s:Subscription.subscription) =
  ["Keeper: " ^ s.keeper_name;"Installation: " ^ s.installation_id;
   "Run: " ^ s.run_id;"Output: " ^ s.output_id]
let target_lines (target:target) = [target.title;"Installation: " ^ target.installation_id;
  "Run: " ^ target.run_id;"Output: " ^ target.output_id;"Observed instance: " ^ target.instance_id]
let lines t =
  ["Keeper subscriptions";"Configuration only: no Keeper wake, read or acknowledgment is performed."]
  @ Option.to_list (Option.map (fun detail -> "Error: " ^ detail) t.error)
  @ match t.phase with
  | Browse index -> ["a:add  d:remove  r:refresh  j/k:select  Esc:back"] @
      (match t.snapshot with
       | None -> [match t.error with None->"Reading subscription configuration…"
           | Some _ -> "No readable subscription configuration."]
       | Some _ -> (match at (entries t) index with
         | None -> ["No subscriptions configured."]
         | Some (entry,state) ->
             [Printf.sprintf "Subscription %d/%d" (index+1) (List.length (entries t))]
             @ identity entry @ (match state with
               | Unavailable detail -> ["Reader state unavailable: " ^ detail]
               | Position {instance_id;acknowledged;latest;replaced} ->
                   ["Observed instance: " ^ instance_id;
                    Printf.sprintf "Acknowledged through sequence %d · latest %d · unread %d" acknowledged latest (latest-acknowledged)]
                   @ (if replaced then ["Producer replaced; new instance reading starts at sequence 1."] else []))
             @ ["Acknowledgment confirms receipt, not source completeness or semantic use.";
                "Reads without acknowledgment are not persisted."]))
  | Keeper index -> [Printf.sprintf "Choose Keeper %d/%d" (index+1) (List.length t.keepers);
      (match at t.keepers index with Some value->value|None->"No Keeper");"j/k:choose  Enter:next  Esc:back"]
  | Output (keeper,index) -> ["Keeper: " ^ keeper;
      Printf.sprintf "Choose output %d/%d" (index+1) (List.length t.targets)]
      @ (match at t.targets index with Some target->target_lines target|None->["No output"])
      @ ["j/k:choose  Enter:review  Esc:back"]
  | Confirm_add (keeper,target) -> ["Add this subscription?"] @ identity (subscription keeper target)
      @ ["Enter:save configuration  Esc:back"]
  | Confirm_remove entry -> ["Remove this subscription?"] @ identity entry
      @ ["Stored reading position is retained. Enter:save configuration  Esc:back"]
