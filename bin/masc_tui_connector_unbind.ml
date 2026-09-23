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
  | Already_unbound
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

(* The server's conditional unbind answers in HTTP statuses: 409 when the
   channel now belongs to a different Keeper (it is left alone), 404 when no
   binding for it remains. Every other non-success is a failure with the
   server's own words. *)
let outcome_of_status ~status ~refusal =
  if status >= 200 && status < 300 then Removed
  else
    match status with
    | 409 -> Rebound
    | 404 -> Already_unbound
    | _ -> Failed refusal

let outcome_text = function
  | Removed -> "removed"
  | Rebound -> "skipped: now bound to another Keeper, left as is"
  | Already_unbound -> "skipped: already unbound"
  | Failed reason -> "FAILED: " ^ Terminal_text.single_line reason

let outcome_line (target, outcome) =
  Printf.sprintf "unbind %s %s: %s"
    (Terminal_text.single_line target.connector_name)
    (target_label target)
    (outcome_text outcome)

type tally = { removed : int; skipped : int; failed : int }

let tally results =
  List.fold_left
    (fun acc (_, outcome) ->
       match outcome with
       | Removed -> { acc with removed = acc.removed + 1 }
       | Rebound | Already_unbound -> { acc with skipped = acc.skipped + 1 }
       | Failed _ -> { acc with failed = acc.failed + 1 })
    { removed = 0; skipped = 0; failed = 0 }
    results

let summary ~keeper_name results =
  let { removed; skipped; failed } = tally results in
  Printf.sprintf "unbind all of %s: %d removed, %d skipped, %d failed"
    keeper_name removed skipped failed

let any_failed results =
  List.exists
    (fun (_, outcome) ->
       match outcome with
       | Failed _ -> true
       | Removed | Rebound | Already_unbound -> false)
    results

let arm_prompt ~keeper_name ~confirm_key targets =
  Printf.sprintf "unbind all armed: press %s again to remove %d binding%s of %s: %s"
    confirm_key (List.length targets)
    (if List.length targets = 1 then "" else "s")
    keeper_name
    (String.concat ", " (List.map target_label targets))

(* The key leads: a footer cuts from the right, and the channel list is the
   part that can be long. *)
let offer_prompt ~keeper_name ~confirm_key targets =
  Printf.sprintf
    "%s: also unbind %s's %d channel%s, or any other key to keep them -- %s"
    confirm_key keeper_name (List.length targets)
    (if List.length targets = 1 then "" else "s")
    (String.concat ", " (List.map target_label targets))
