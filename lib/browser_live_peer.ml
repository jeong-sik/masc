type partial_failure = { tab_id : int; message : string; receipt : Yojson.Safe.t }
type disposition = Not_started | Uncertain
type failure = Before_effect of string | Partial_failure of partial_failure | Outcome_unknown of string
  | Observed_failure of { disposition : disposition; message : string; receipt : Yojson.Safe.t }
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact | Page_act
  | Page_goto | Page_context | Page_snapshot | Page_downloads | Page_native_workflow
[@@deriving enumerate]
let verb_to_wire = function
  | Browser_info -> "browser.info" | Tabs_list -> "tabs.list" | Page_read -> "page.read"
  | Page_scene -> "page.scene" | Page_elements -> "page.elements" | Page_capture -> "page.capture"
  | Page_native_workflow -> "page.native_workflow"
  | Page_interact -> "page.interact" | Page_act -> "page.act" | Page_goto -> "page.goto" | Page_context -> "page.context"
  | Page_snapshot -> "page.snapshot" | Page_downloads -> "page.downloads"
let verb_of_wire s = List.find_opt (fun v -> String.equal (verb_to_wire v) s) all_of_verb
open Result.Syntax
let decode (issued : Browser_lane.issued) =
  let* fields = match issued.verb_json with `Assoc fields -> Ok fields | _ -> Error "invalid live command" in
  let* () = if List.for_all (fun (name,_) -> List.mem name ["verb";"args";"actor"]) fields
      && List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
    then Ok () else Error "invalid live command fields" in
  let* verb = match List.assoc_opt "verb" fields with
    | Some (`String name) -> Option.to_result ~none:"unsupported live verb" (verb_of_wire name)
    | None | Some _ -> Error "missing live verb" in
  let* args = match List.assoc_opt "args" fields with
    | Some (`Assoc _ as args) -> Ok args
    | None | Some _ -> Error "invalid live command arguments" in
  let* actor = match List.assoc_opt "actor" fields with
    | None -> Ok None
    | Some (`String actor) when String.trim actor <> "" -> Ok (Some actor)
    | Some _ -> Error "invalid live command actor" in
  Ok (verb, args, actor)
let payload = function
  | Ok data -> `Assoc ["ok",`Bool true;"data",data]
  | Error (Before_effect detail) -> `Assoc ["ok",`Bool false;"error",`String detail;"effectPhase",`String "not_started"]
  | Error (Partial_failure {message;receipt;_}) -> `Assoc ["ok",`Bool false;"error",`String message;
      "effectPhase",`String "partial";"data",receipt]
  | Error (Outcome_unknown detail) -> `Assoc ["ok",`Bool false;"error",`String detail]
  | Error (Observed_failure {disposition;message;receipt}) ->
    let phase = match disposition with Not_started -> ["effectPhase",`String "not_started"] | Uncertain -> [] in
    `Assoc (["ok",`Bool false;"error",`String message;"data",receipt] @ phase)
