(** Keeper_turn_setup -- keeper setup helpers.

    Extracted from keeper_turn.ml. Provides [ensure_keeper_exists]. *)

open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

(* A name this surface refused can be two different things, and a reader acts
   differently on each: a keeper that is gone is worth looking for, while an
   agent was never a keeper and no amount of looking will help. Both answered
   "keeper not found", which sends the reader after the first one. The roster
   read happens only on the refusal path, and a failed read falls back to the
   plain wording rather than claiming anything about the name. *)
let name_is_known_agent ~(config : Workspace.config) name =
  try
    List.exists
      (fun (agent : Masc_domain.agent) -> String.equal agent.name name)
      (Workspace.get_active_agents config)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> false
;;

(* A caller that names a keeper that does not exist guesses again, and a guess
   costs a turn. In the 240 hours to 2026-11-11 12:44 KST, 36 of 2,304
   masc_keeper_delegate calls were refused, 26 of them with "keeper not found";
   11 of the 36 were followed within three minutes by a masc_keeper_list read
   of about 55 KB, and 20 by another delegate call. The refusal names the
   keepers it would have accepted, so the next call needs no roster read. A
   workspace with more names than the limit gets the first ones and how many
   were left out. *)
let absent_roster_name_limit = 40

let absent_roster_clause names =
  match List.sort_uniq String.compare names with
  | [] -> ""
  | sorted ->
    let shown = List.filteri (fun index _ -> index < absent_roster_name_limit) sorted in
    let rest = List.length sorted - List.length shown in
    Printf.sprintf
      "; registered keepers: %s%s"
      (String.concat ", " shown)
      (if rest > 0
       then Printf.sprintf " (+%d more, masc_keeper_list lists them all)" rest
       else "")
;;

let registered_keeper_names ~(config : Workspace.config) =
  Keeper_registry.all ~base_path:config.base_path ()
  |> List.map (fun (entry : Keeper_registry.registry_entry) -> entry.name)
;;

let keeper_absent_detail ~(config : Workspace.config) name =
  if name_is_known_agent ~config name
  then
    Printf.sprintf
      "%s is an agent, not a keeper; this surface takes keeper names"
      name
  else
    Printf.sprintf
      "keeper not found: %s%s"
      name
      (absent_roster_clause (registered_keeper_names ~config))
;;

let ensure_keeper_exists ~(ctx : _ context) ~name : (keeper_meta, string) result =
  match read_effective_meta_resolved ctx.config name with
  | Error e -> Error e
  | Ok (Some (_resolved_name, m)) -> Ok m
  | Ok None -> Error (keeper_absent_detail ~config:ctx.config name)
