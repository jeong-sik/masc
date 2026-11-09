(* Keeper_turn_system — the System a keeper turn sends, and the articles that
   changed since it was rendered (RFC-0491 §3.2). See the mli. *)

open Result.Syntax

type t =
  { text : string
  ; amendments : string option
  ; withheld : string option
  }

type stored =
  { at : World_constitution_store.position
  ; system_digest : string
  }

type basis =
  { articles : World_constitution_types.t list
  ; stored : stored
  }

module Runtime_map = Map.Make (String)

type held =
  { issued : stored
  ; by_runtime : stored Runtime_map.t
  }

type front =
  | Same_front
  | Moved_front
  | No_previous_request

(* A range carries at least its newest atom, so the predicted first atom
   always has a message; [None] there names no position to compare. *)
let front ~digest_at ~first_atom ~(previous : Keeper_carried_front.seed option) =
  match previous, digest_at first_atom with
  | None, (Some _ | None) -> No_previous_request
  | Some previous, Some digest
    when previous.first_atom = first_atom
         && Model_input_front.equal previous.front (Model_input_front.At_atom digest) ->
    Same_front
  | Some _, (Some _ | None) -> Moved_front
;;

let digest text = Agent_core_sha256.(digest_string text |> to_hex)
let basis ~articles ~at ~system = { articles; stored = { at; system_digest = digest system } }

type decision =
  | From_basis of
      { text : string
      ; amendments : World_constitution_render.amendments option
      ; basis : basis
      }
  | From_current of { text : string }

let decide ~front ~basis ~render ~current =
  let from_current () = From_current { text = render current } in
  match front, basis with
  | Same_front, Some basis ->
    let text = render basis.articles in
    if String.equal (digest text) basis.stored.system_digest
    then
      From_basis
        { text
        ; amendments = World_constitution_render.amendments ~built_with:basis.articles current
        ; basis
        }
    else from_current ()
  | Same_front, None | (Moved_front | No_previous_request), (Some _ | None) -> from_current ()
;;

type lane =
  | Agent_core of
      { runtime_id : string
      ; front : front
      }
  | Without_basis

let block amendments = Option.map Keeper_prompt.constitution_amendments_block amendments

(* The articles a stored basis names, when the ledger still begins with the
   bytes it was read from. *)
let resolve ~articles_at stored =
  let* articles = articles_at stored.at in
  Ok (Option.map (fun articles -> { articles; stored }) articles)
;;

let issue ~held ~lane ~render ~current ~at ~articles_at =
  let by_runtime = Option.fold ~none:Runtime_map.empty ~some:(fun held -> held.by_runtime) held in
  let from_current text = { at; system_digest = digest text } in
  match lane with
  | Without_basis ->
    let text = render current in
    Ok ({ text; amendments = None; withheld = None }, { issued = from_current text; by_runtime })
  | Agent_core { runtime_id; front } ->
    let* basis =
      match front, Runtime_map.find_opt runtime_id by_runtime with
      | Same_front, Some stored -> resolve ~articles_at stored
      | Same_front, None | (Moved_front | No_previous_request), (Some _ | None) -> Ok None
    in
    Ok
      (match decide ~front ~basis ~render ~current with
       | From_basis { text; amendments; basis } ->
         { text; amendments = block amendments; withheld = None }, { issued = basis.stored; by_runtime }
       | From_current { text } ->
         let stored = from_current text in
         ( { text; amendments = None; withheld = None }
         , { issued = stored; by_runtime = Runtime_map.add runtime_id stored by_runtime } ))
;;

let resend ~held ~runtime_id ~current ~articles_at recorded =
  let unknown = { text = recorded; amendments = None; withheld = None } in
  match held with
  | Some held when String.equal held.issued.system_digest (digest recorded) ->
    let* basis = resolve ~articles_at held.issued in
    Ok
      (match basis with
       | Some basis ->
         ( { text = recorded
           ; amendments =
               block (World_constitution_render.amendments ~built_with:basis.articles current)
           ; withheld = None
           }
         , Some { held with by_runtime = Runtime_map.add runtime_id held.issued held.by_runtime } )
       | None -> unknown, Some held)
  | Some _ | None -> Ok (unknown, held)
;;

let with_withheld ids issued =
  let withheld = match ids with
    | [] -> None
    | _ :: _ -> Some (Keeper_prompt.constitution_withheld_block ids)
  in
  { issued with withheld }
;;

let with_bytes ~issued text =
  if String.equal issued.text text then issued
  else { issued with text; amendments = None }
;;

(* Session checkpoint form. The schema is closed: a missing, unknown or
   duplicated field is a rejection. *)

let context_key = "keeper_turn_system"
let field_issued = "issued"
let field_by_runtime = "by_runtime"
let field_runtime_id = "runtime_id"
let field_ledger_end = "ledger_end"
let field_ledger_digest = "ledger_digest"
let field_system_digest = "system_digest"

let stored_fields { at; system_digest } =
  [ field_ledger_end, `Int at.World_constitution_store.end_offset
  ; field_ledger_digest, `String at.World_constitution_store.digest
  ; field_system_digest, `String system_digest
  ]
;;

let held_to_json { issued; by_runtime } =
  `Assoc
    [ field_issued, `Assoc (stored_fields issued)
    ; ( field_by_runtime
      , `List
          (Runtime_map.bindings by_runtime
           |> List.map (fun (runtime_id, stored) ->
             `Assoc ((field_runtime_id, `String runtime_id) :: stored_fields stored))) )
    ]
;;

(* Exactly [names], each once: equal counts and every name present leave no
   room for an extra or a repeated field. *)
let exact_fields ~at names = function
  | `Assoc fields
    when List.compare_lengths fields names = 0
         && List.for_all (fun name -> List.mem_assoc name fields) names -> Ok fields
  | `Assoc _ -> Error (Printf.sprintf "%s: the fields are exactly %s" at (String.concat ", " names))
  | _ -> Error (at ^ ": expected an object")
;;

let field ~at name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s: missing" at name)
;;

let string_field ~at name fields =
  let* value = field ~at name fields in
  match value with
  | `String text -> Ok text
  | _ -> Error (Printf.sprintf "%s.%s: expected a string" at name)
;;

let int_field ~at name fields =
  let* value = field ~at name fields in
  match value with
  | `Int number -> Ok number
  | _ -> Error (Printf.sprintf "%s.%s: expected an integer" at name)
;;

let stored_of_fields ~at fields =
  let* end_offset = int_field ~at field_ledger_end fields in
  let* ledger_digest = string_field ~at field_ledger_digest fields in
  let* system_digest = string_field ~at field_system_digest fields in
  Ok { at = { World_constitution_store.end_offset; digest = ledger_digest }; system_digest }
;;

let stored_names = [ field_ledger_end; field_ledger_digest; field_system_digest ]

let held_of_json json =
  let at = context_key in
  let* fields = exact_fields ~at [ field_issued; field_by_runtime ] json in
  let* issued_json = field ~at field_issued fields in
  let issued_at = at ^ "." ^ field_issued in
  let* issued_fields = exact_fields ~at:issued_at stored_names issued_json in
  let* issued = stored_of_fields ~at:issued_at issued_fields in
  let* items =
    let* value = field ~at field_by_runtime fields in
    match value with
    | `List items -> Ok items
    | _ -> Error (Printf.sprintf "%s.%s: expected an array" at field_by_runtime)
  in
  let* by_runtime =
    List.fold_left
      (fun acc (index, item) ->
         let* map = acc in
         let item_at = Printf.sprintf "%s.%s[%d]" at field_by_runtime index in
         let* item_fields = exact_fields ~at:item_at (field_runtime_id :: stored_names) item in
         let* runtime_id = string_field ~at:item_at field_runtime_id item_fields in
         let* stored = stored_of_fields ~at:item_at item_fields in
         if Runtime_map.mem runtime_id map
         then Error (Printf.sprintf "%s: runtime %s appears twice" item_at runtime_id)
         else Ok (Runtime_map.add runtime_id stored map))
      (Ok Runtime_map.empty)
      (List.mapi (fun index item -> index, item) items)
  in
  Ok { issued; by_runtime }
;;

let read context =
  match Agent_core.Context.get_scoped context Agent_core.Context.Session context_key with
  | None -> Ok None
  | Some json -> held_of_json json |> Result.map Option.some
;;

let write context held =
  Agent_core.Context.set_scoped context Agent_core.Context.Session context_key (held_to_json held)
;;
