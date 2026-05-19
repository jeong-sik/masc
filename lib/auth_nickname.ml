(** Generated credential alias nickname helpers for Auth. *)

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;
let nickname_adjectives =
  [| "swift"
   ; "brave"
   ; "calm"
   ; "eager"
   ; "fierce"
   ; "gentle"
   ; "happy"
   ; "jolly"
   ; "keen"
   ; "lucky"
   ; "merry"
   ; "noble"
   ; "proud"
   ; "quick"
   ; "witty"
   ; "bold"
   ; "cool"
   ; "deft"
   ; "fair"
   ; "grand"
   ; "hale"
   ; "jade"
   ; "kind"
   ; "lean"
   ; "neat"
   ; "pale"
   ; "rare"
   ; "sage"
   ; "tame"
   ; "warm"
  |]
;;

let nickname_animals =
  [| "fox"
   ; "bear"
   ; "wolf"
   ; "hawk"
   ; "lion"
   ; "tiger"
   ; "eagle"
   ; "otter"
   ; "panda"
   ; "koala"
   ; "raven"
   ; "falcon"
   ; "badger"
   ; "beaver"
   ; "whale"
   ; "shark"
   ; "crane"
   ; "heron"
   ; "moose"
   ; "viper"
   ; "cobra"
   ; "gecko"
   ; "lemur"
   ; "llama"
   ; "manta"
   ; "orca"
   ; "rhino"
   ; "sloth"
   ; "tapir"
   ; "zebra"
  |]
;;

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
    | prefix -> String.concat "-" prefix |> trim_nonempty
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

(* Inline copy of Nickname.is_generated_nickname / extract_agent_type.
   Auth lives below masc_coord in the module graph and cannot depend on
   it. The nickname pattern — stable-prefix + adjective + animal
   [+ hex4] — is duplicated here so auth can canonicalize generated
   aliases without depending on Nickname. Keeper aliases use a
   different canonical shape
   (keeper-<name>-agent) and must resolve to the middle segment so
   keeper-scoped credentials can be stored under the stable keeper name
   rather than the transport alias. Covered by the nickname fallback
   tests. *)
let is_generated_nickname_shape name = List.length (String.split_on_char '-' name) >= 3

let keeper_transport_alias_stable_name name =
  match String.split_on_char '-' name with
  | "keeper" :: rest ->
    (match List.rev rest with
     | "agent" :: middle_rev -> List.rev middle_rev |> String.concat "-" |> trim_nonempty
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
