module Reading = Masc.Tui_decode
module Terminal_text = Masc_tui_ansi.Terminal_text

let unbind_all_key = "U"

type target = {
  connector_id : string;
  connector_name : string;
  channel_id : string;
  channel_name : string option;
  keeper_name : string;
}

type outcome =
  | Removed
  | Rebound
  | Not_found of string
  | Failed of string
  | Kept_back of string

let channel_label ~ko ~channel_id ~channel_name =
  match channel_name with
  | Some name ->
      Printf.sprintf "%s (%s)"
        (Terminal_text.single_line name)
        (Terminal_text.single_line channel_id)
  | None ->
      Terminal_text.single_line channel_id
      ^ if ko then " (이름 보고 안 됨)" else " (name not reported)"

(* Every sentence that names a target below is English, so the label inside
   it is English too. *)
let target_label target =
  channel_label ~ko:false ~channel_id:target.channel_id
    ~channel_name:target.channel_name

let target_of_binding (connector : Masc.Tui_decode_connectors.connector)
    (binding : Masc.Tui_decode_connectors.connector_binding) =
  { connector_id = connector.cn_id
  ; connector_name = connector.cn_display_name
  ; channel_id = binding.cb_channel_id
  ; channel_name = binding.cb_channel_name
  ; keeper_name = binding.cb_keeper_name
  }

let targets ~keeper_name (connectors : Masc.Tui_decode_connectors.connector list) =
  List.concat_map
    (fun (connector : Masc.Tui_decode_connectors.connector) ->
       List.filter_map
         (fun (binding : Masc.Tui_decode_connectors.connector_binding) ->
            if String.equal binding.cb_keeper_name keeper_name then
              Some (target_of_binding connector binding)
            else None)
         connector.cn_bindings)
    connectors

type next_press =
  | Nothing_bound
  | Asks of target list
  | Sends of target list

let next_press ~named ~keeper_name targets =
  match targets, named with
  | [], (Some _ | None) -> Nothing_bound
  | _ :: _, Some (named_keeper, named_targets)
    when String.equal named_keeper keeper_name && named_targets = targets ->
      Sends targets
  | _ :: _, (Some _ | None) -> Asks targets

let unreadable_transports (connectors : Masc.Tui_decode_connectors.connector list) =
  List.filter_map
    (fun (connector : Masc.Tui_decode_connectors.connector) ->
       match connector.cn_binding_store_read_ok with
       | Some false -> Some (Terminal_text.single_line connector.cn_display_name)
       | Some true | None -> None)
    connectors

(* The server's conditional unbind answers in HTTP statuses: 409 when the
   channel now belongs to a different Keeper (it is left alone). A 404 is
   "no such binding" from the store, but the route also answers 404 for a
   connector it does not know, so it keeps the server's words rather than
   claiming the binding was already gone. Every other non-success is a
   failure with the server's own words. *)
let outcome_of_status ~status ~refusal =
  if Reading.is_success_http_status status then Removed
  else
    match status with
    | 409 -> Rebound
    | 404 -> Not_found refusal
    | _ -> Failed refusal

let outcome_text = function
  | Removed -> "removed"
  | Rebound -> "kept: now bound to another Keeper"
  | Not_found words -> "not removed, server found nothing: " ^ Terminal_text.single_line words
  | Failed reason -> "FAILED: " ^ Terminal_text.single_line reason
  | Kept_back notice -> notice

(* A kept-back notice leads its line, drawn alone, with the binding after it
   (RFC-tui-one-screen-grammar §2). *)
let outcome_line (target, outcome) =
  match outcome with
  | Kept_back _ ->
      Printf.sprintf "%s · %s %s" (outcome_text outcome)
        (Terminal_text.single_line target.connector_name) (target_label target)
  | Removed | Rebound | Not_found _ | Failed _ ->
      Printf.sprintf "unbind %s %s: %s"
        (Terminal_text.single_line target.connector_name)
        (target_label target)
        (outcome_text outcome)

(* Failures last: the event log keeps a handful of rows, and the lines that
   need acting on are the ones that must still be there when it is read. *)
let report_rank = function
  | Removed -> 0
  | Rebound -> 1
  | Not_found _ -> 2
  | Kept_back _ -> 3
  | Failed _ -> 4

let report_order results =
  List.stable_sort
    (fun (_, left) (_, right) -> compare (report_rank left) (report_rank right))
    results

let count predicate results =
  List.length (List.filter (fun (_, outcome) -> predicate outcome) results)

let summary ~keeper_name results =
  let removed = count (function Removed -> true | Rebound | Not_found _ | Failed _ | Kept_back _ -> false) results in
  let rebound = count (function Rebound -> true | Removed | Not_found _ | Failed _ | Kept_back _ -> false) results in
  let not_found = count (function Not_found _ -> true | Removed | Rebound | Failed _ | Kept_back _ -> false) results in
  let not_sent = count (function Kept_back _ -> true | Removed | Rebound | Not_found _ | Failed _ -> false) results in
  let failed =
    List.filter_map
      (fun (target, outcome) ->
         match outcome with
         | Failed _ -> Some (target_label target)
         | Removed | Rebound | Not_found _ | Kept_back _ -> None)
      results
  in
  Printf.sprintf
    "unbind all of %s: %d removed, %d kept, %d not found%s, %d failed%s"
    (Terminal_text.single_line keeper_name)
    removed rebound not_found
    (if not_sent = 0 then "" else Printf.sprintf ", %d not sent" not_sent)
    (List.length failed)
    (match failed with
     | [] -> ""
     | labels -> " -- " ^ String.concat ", " labels)

let any_failed results =
  List.exists
    (fun (_, outcome) ->
       match outcome with
       | Failed _ -> true
       | Removed | Rebound | Not_found _ | Kept_back _ -> false)
    results

let any_kept_back results =
  List.exists
    (fun (_, outcome) ->
       match outcome with
       | Kept_back _ -> true
       | Removed | Rebound | Not_found _ | Failed _ -> false)
    results

let unreadable_note = function
  | [] -> ""
  | names ->
      "; not included, binding list unreadable: " ^ String.concat ", " names

(* The key leads and the channels are not repeated: the Channels tab lists
   every one of them, and a footer cuts a long list from the right. *)
let arm_prompt ~keeper_name ~confirm_key ~unreadable targets =
  Printf.sprintf
    "unbind all armed: press %s again to remove the %d binding%s of %s listed \
     on the Channels tab%s"
    confirm_key (List.length targets)
    (if List.length targets = 1 then "" else "s")
    (Terminal_text.single_line keeper_name)
    (unreadable_note unreadable)

let nothing_to_unbind ~keeper_name ~unreadable =
  Printf.sprintf "unbind all: %s has no channel bindings%s"
    (Terminal_text.single_line keeper_name)
    (unreadable_note unreadable)

(* Not [U]: on the Keeper list [U] opens the runtime picker, and "pause,
   then pick another runtime" is an ordinary sequence. A key the Keeper
   surfaces bind to nothing else cannot be typed for something else. *)
let offer_key = "y"

type offer = {
  offer_keeper : string;
  offer_targets : target list;
  offered_at : int;
}

type offer_reading =
  | Offer_waits
  | Offer_accepted
  | Offer_dropped

let read_offer_input offer ~frames_presented ~input_seen ~key =
  if not input_seen then Offer_waits
  else if frames_presented <= offer.offered_at then Offer_dropped
  else
    match key with
    | Some pressed when String.equal pressed offer_key -> Offer_accepted
    | Some _ | None -> Offer_dropped

type confirmation = {
  confirm_key : string;
  confirm_targets : target list;
}

(* The TUI never holds both: an offer is made only while nothing is armed,
   and the [U] that arms is a key the offer reads first and drops on. The
   arm is read first only so every pair of fields has an answer. *)
let confirmation ~armed ~offer ~keeper_name targets =
  let sends key named =
    match next_press ~named ~keeper_name targets with
    | Sends targets -> Some { confirm_key = key; confirm_targets = targets }
    | Nothing_bound | Asks _ -> None
  in
  match sends unbind_all_key armed with
  | Some armed_confirmation -> Some armed_confirmation
  | None ->
      Option.bind offer (fun offer ->
        sends offer_key (Some (offer.offer_keeper, offer.offer_targets)))

type row_mark =
  | Will_unbind of string
  | Not_targeted

let row_mark confirmation connector binding =
  match confirmation with
  | None -> Not_targeted
  | Some { confirm_key; confirm_targets } ->
      if List.mem (target_of_binding connector binding) confirm_targets then
        Will_unbind confirm_key
      else Not_targeted

(* The key leads: a footer cuts from the right, and the channel list is the
   part that can be long. *)
let offer_prompt ~keeper_name ~unreadable targets =
  Printf.sprintf
    "%s: also unbind %s's %d channel%s, or any other key to keep them -- %s%s"
    offer_key
    (Terminal_text.single_line keeper_name)
    (List.length targets)
    (if List.length targets = 1 then "" else "s")
    (String.concat ", " (List.map target_label targets))
    (unreadable_note unreadable)

let still_bound ~keeper_name targets =
  Printf.sprintf "%s still holds %d channel binding%s; %s %s on its Channels \
                  tab removes them"
    (Terminal_text.single_line keeper_name)
    (List.length targets)
    (if List.length targets = 1 then "" else "s")
    unbind_all_key unbind_all_key

let offer_read_failed ~keeper_name ~detail =
  Printf.sprintf
    "unbind-all offer for %s unavailable: %s"
    (Terminal_text.single_line keeper_name)
    (Terminal_text.single_line detail)

(* The read the offer waited for was not sent: its kept-back notice alone,
   then the Keeper (RFC §2). *)
let offer_read_kept_back ~keeper_name ~notice =
  Terminal_text.single_line notice ^ " · " ^ Terminal_text.single_line keeper_name
