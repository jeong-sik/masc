module Reading = Masc.Tui_decode
module Terminal_text = Masc_tui_ansi.Terminal_text

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

let channel_label ~channel_id ~channel_name =
  match channel_name with
  | Some name ->
      Printf.sprintf "%s (%s)"
        (Terminal_text.single_line name)
        (Terminal_text.single_line channel_id)
  | None -> Terminal_text.single_line channel_id ^ " (name unknown)"

let target_label target =
  channel_label ~channel_id:target.channel_id ~channel_name:target.channel_name

let targets ~keeper_name (connectors : Reading.connector list) =
  List.concat_map
    (fun (connector : Reading.connector) ->
       List.filter_map
         (fun (binding : Reading.connector_binding) ->
            if String.equal binding.cb_keeper_name keeper_name then
              Some
                { connector_id = connector.cn_id
                ; connector_name = connector.cn_display_name
                ; channel_id = binding.cb_channel_id
                ; channel_name = binding.cb_channel_name
                ; keeper_name = binding.cb_keeper_name
                }
            else None)
         connector.cn_bindings)
    connectors

let unreadable_transports (connectors : Reading.connector list) =
  List.filter_map
    (fun (connector : Reading.connector) ->
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

let outcome_line (target, outcome) =
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
  | Failed _ -> 3

let report_order results =
  List.stable_sort
    (fun (_, left) (_, right) -> compare (report_rank left) (report_rank right))
    results

let count predicate results =
  List.length (List.filter (fun (_, outcome) -> predicate outcome) results)

let summary ~keeper_name results =
  let removed = count (function Removed -> true | Rebound | Not_found _ | Failed _ -> false) results in
  let rebound = count (function Rebound -> true | Removed | Not_found _ | Failed _ -> false) results in
  let not_found = count (function Not_found _ -> true | Removed | Rebound | Failed _ -> false) results in
  let failed =
    List.filter_map
      (fun (target, outcome) ->
         match outcome with
         | Failed _ -> Some (target_label target)
         | Removed | Rebound | Not_found _ -> None)
      results
  in
  Printf.sprintf
    "unbind all of %s: %d removed, %d kept, %d not found, %d failed%s"
    (Terminal_text.single_line keeper_name)
    removed rebound not_found (List.length failed)
    (match failed with
     | [] -> ""
     | labels -> " -- " ^ String.concat ", " labels)

let any_failed results =
  List.exists
    (fun (_, outcome) ->
       match outcome with
       | Failed _ -> true
       | Removed | Rebound | Not_found _ -> false)
    results

let unreadable_note = function
  | [] -> ""
  | names ->
      "; not included, binding list unreadable: " ^ String.concat ", " names

let arm_prompt ~keeper_name ~confirm_key ~unreadable targets =
  Printf.sprintf "unbind all armed: press %s again to remove %d binding%s of %s: %s%s"
    confirm_key (List.length targets)
    (if List.length targets = 1 then "" else "s")
    (Terminal_text.single_line keeper_name)
    (String.concat ", " (List.map target_label targets))
    (unreadable_note unreadable)

let nothing_to_unbind ~keeper_name ~unreadable =
  Printf.sprintf "unbind all: %s has no channel bindings%s"
    (Terminal_text.single_line keeper_name)
    (unreadable_note unreadable)
