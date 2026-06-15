(** Generated credential alias nickname helpers for Auth. *)

;;
(* Adjective/animal vocabulary comes from the shared [Nickname_words] SSOT
   (masc.config). Auth previously inlined a copy to avoid depending on
   [Nickname]; reading the shared lists keeps this classifier from drifting away
   from the generator. *)
let nickname_adjectives = Nickname_words.adjectives
let nickname_animals = Nickname_words.animals

let array_contains arr value =
  let rec loop idx =
    idx < Array.length arr && (String.equal arr.(idx) value || loop (idx + 1))
  in
  loop 0
;;

let is_hex4 value =
  String.length value = 4
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let extract_generated_nickname_prefix name =
  let parts = String.split_on_char '-' name in
  let join_prefix prefix_rev =
    match List.rev prefix_rev with
    | [] -> None
    | prefix -> String.concat "-" prefix |> String_util.trim_nonempty
  in
  match List.rev parts with
  | animal :: adjective :: prefix_rev
    when array_contains nickname_animals animal
         && array_contains nickname_adjectives adjective -> join_prefix prefix_rev
  | suffix :: animal :: adjective :: prefix_rev
    when is_hex4 suffix
         && array_contains nickname_animals animal
         && array_contains nickname_adjectives adjective -> join_prefix prefix_rev
  | prefix :: _ when prefix <> "" -> Some prefix
  | _ -> None
;;

(* The nickname classification logic (shape check + prefix extraction) mirrors
   Nickname's, kept inline because auth lives below masc_workspace in the module
   graph and cannot depend on Nickname. The adjective/animal word lists are no
   longer duplicated — they come from the shared Nickname_words (masc.config)
   above, so the two paths cannot drift. Keeper aliases use a different
   canonical shape (keeper-<name>-agent) and must resolve to the middle segment
   so keeper-scoped credentials can be stored under the stable keeper name
   rather than the transport alias. Covered by the nickname fallback tests. *)
let is_generated_nickname_shape name = List.length (String.split_on_char '-' name) >= 3

let keeper_transport_alias_stable_name name =
  match String.split_on_char '-' name with
  | "keeper" :: rest ->
    (match List.rev rest with
     | "agent" :: middle_rev -> List.rev middle_rev |> String.concat "-" |> String_util.trim_nonempty
     | _ -> None)
  | _ -> None
;;

let extract_agent_type_prefix name =
  match keeper_transport_alias_stable_name name with
  | Some stable_name -> Some stable_name
  | None ->
    (match String.split_on_char '-' name with
     | "keeper" :: _ -> Some "keeper"
     | _ -> extract_generated_nickname_prefix name)
;;

let credential_agent_name agent_name =
  match extract_agent_type_prefix agent_name with
  | Some prefix when prefix <> agent_name -> prefix
  | _ -> agent_name
;;
