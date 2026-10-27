type slot =
  | Whole_write
  | Developer_instructions
  | Dynamic_tools
  | Injected_item of int
  | Turn_text of int
  | Unattributed_carrier

type encoding =
  | Json_line
  | Raw

type fragment =
  { slot : slot
  ; offset : int option
  ; bytes : int
  ; sha256 : string
  }

type fragments =
  | Partitioned of fragment list
  | Serialization_mismatch

type t =
  { encoding : encoding
  ; bytes : int
  ; sha256 : string
  ; fragments : fragments
  }

type selection =
  | Select of slot
  | Fields of (string * selection) list
  | Elements of (int -> Yojson.Safe.t -> selection)
  | Carry

let sha256_hex text = Agent_core_sha256.(digest_string text |> to_hex)

(* End offset of the JSON value starting at [pos] in compact serializer output,
   or [None] when those bytes are not one complete value. Strings end at their
   first unescaped quote; containers at the bracket that closes depth one,
   skipping brackets inside strings; scalars at the next delimiter. *)
let json_value_end payload pos =
  let length = String.length payload in
  let rec string_end i =
    if i >= length then None
    else match payload.[i] with
      | '\\' -> string_end (i + 2)
      | '"' -> Some (i + 1)
      | _ -> string_end (i + 1) in
  let rec container_end depth i =
    if i >= length then None
    else match payload.[i] with
      | '"' -> Option.bind (string_end (i + 1)) (container_end depth)
      | '{' | '[' -> container_end (depth + 1) (i + 1)
      | '}' | ']' -> if depth = 1 then Some (i + 1) else container_end (depth - 1) (i + 1)
      | _ -> container_end depth (i + 1) in
  let rec scalar_end i = match payload.[i] with
    | ',' | '}' | ']' -> i
    | _ -> if i + 1 >= length then length else scalar_end (i + 1) in
  if pos >= length then None
  else match payload.[pos] with
    | '"' -> string_end (pos + 1)
    | '{' | '[' -> container_end 0 pos
    | ',' | '}' | ']' | ':' -> None
    | _ -> Some (scalar_end pos)
;;

(* Ranges are read from [payload], the bytes actually written, never from a
   second serialization: a large image or output schema is not copied again
   before the write deadline. Selected ranges are hashed in place and the
   unselected gaps feed one incremental hash. The walk follows [json]'s
   structure and checks every key and delimiter against the payload, so a
   serializer layout it does not expect leaves attribution unavailable instead
   of claiming offsets. *)
let json_fragments selection json payload =
  let length = String.length payload in
  let exception Layout_mismatch in
  let cursor = ref 0 in
  let fragments = ref [] in
  let residual = ref Agent_core_sha256.empty and residual_bytes = ref 0 in
  let carry stop =
    residual := Agent_core_sha256.feed_string !residual ~off:!cursor ~len:(stop - !cursor) payload;
    residual_bytes := !residual_bytes + (stop - !cursor);
    cursor := stop in
  let literal text =
    let stop = !cursor + String.length text in
    if stop > length || not (String.equal (String.sub payload !cursor (String.length text)) text)
    then raise Layout_mismatch;
    carry stop in
  let value_end () = match json_value_end payload !cursor with
    | Some stop -> stop | None -> raise Layout_mismatch in
  let ordinary () = carry (value_end ()) in
  let selected slot value =
    let opener = match value with
      | `String _ -> '"' | `List _ -> '[' | `Assoc _ -> '{' | _ -> raise Layout_mismatch in
    if !cursor >= length || payload.[!cursor] <> opener then raise Layout_mismatch;
    let offset = !cursor and stop = value_end () in
    fragments := {slot;offset=Some offset;bytes=stop - offset;
      sha256=Agent_core_sha256.(digest_string ~off:offset ~len:(stop - offset) payload |> to_hex)}
      :: !fragments;
    cursor := stop in
  let rec visit selection value = match selection, value with
    | Select slot, _ -> selected slot value
    | Fields named, `Assoc fields ->
      literal "{";
      List.iteri (fun index (key, member) ->
        if index > 0 then literal ",";
        literal (Yojson.Safe.to_string (`String key)); literal ":";
        match List.assoc_opt key named with
        | Some selection -> visit selection member
        | None -> ordinary ()) fields;
      literal "}"
    | Elements select, `List values ->
      literal "[";
      List.iteri (fun index member ->
        if index > 0 then literal ",";
        visit (select index member) member) values;
      literal "]"
    | (Fields _ | Elements _ | Carry), _ -> ordinary () in
  match visit selection json; if !cursor <> length then raise Layout_mismatch with
  | exception Layout_mismatch -> Serialization_mismatch
  | () ->
    Partitioned (List.rev !fragments @
      [{slot=Unattributed_carrier;offset=None;bytes= !residual_bytes;
        sha256=Agent_core_sha256.(get !residual |> to_hex)}])
;;

let json_line selection json payload =
  { encoding = Json_line
  ; bytes = String.length payload
  ; sha256 = sha256_hex payload
  ; fragments = json_fragments selection json payload
  }
;;

let raw text =
  let bytes = String.length text and sha256 = sha256_hex text in
  { encoding = Raw
  ; bytes
  ; sha256
  ; fragments = Partitioned [ { slot = Whole_write; offset = Some 0; bytes; sha256 } ]
  }
;;

let turn_input =
  Elements (fun index -> function
    | `Assoc fields when List.assoc_opt "type" fields = Some (`String "text") ->
      Fields [ "text", Select (Turn_text index) ]
    | _ -> Carry)
;;

let encode_text write text = match write.encoding with
  | Json_line -> Yojson.Safe.to_string (`String text)
  | Raw -> text
;;

let encoded_text_sha256 write text = sha256_hex (encode_text write text)

let matching_fragment write ~slot text =
  let encoded = encode_text write text in
  match write.fragments with
  | Serialization_mismatch -> None
  | Partitioned fragments ->
    let digest = sha256_hex encoded in
    List.find_opt (fun fragment ->
      fragment.slot = slot && fragment.bytes = String.length encoded
      && String.equal fragment.sha256 digest) fragments
;;

let slot_fields slot =
  let name, index = match slot with
    | Whole_write -> "whole_write", None
    | Developer_instructions -> "developer_instructions", None
    | Dynamic_tools -> "dynamic_tools", None
    | Injected_item index -> "injected_item", Some index
    | Turn_text index -> "turn_text", Some index
    | Unattributed_carrier -> "unattributed_carrier", None in
  [ "slot", `String name
  ; "index", (match index with None -> `Null | Some index -> `Int index) ]
;;

let fragment_to_json fragment =
  `Assoc (slot_fields fragment.slot @
    [ "offset", (match fragment.offset with None -> `Null | Some offset -> `Int offset)
    ; "bytes", `Int fragment.bytes
    ; "sha256", `String fragment.sha256 ])
;;

let to_json write =
  let encoding, framing = match write.encoding with
    | Json_line -> "json_line", "json_followed_by_lf_hash_excludes_lf"
    | Raw -> "raw", "bytes_as_written" in
  let fragments = match write.fragments with
    | Partitioned values ->
      `Assoc (("status", `String "partitioned")
        :: ("values", `List (List.map fragment_to_json values))
        :: (match write.encoding with
            | Json_line -> [ "residual_hash_basis", `String "ordered_unselected_json_bytes" ]
            | Raw -> []))
    | Serialization_mismatch ->
      `Assoc [ "status", `String "unavailable"; "reason", `String "serialization_mismatch" ] in
  `Assoc
    [ "encoding", `String encoding
    ; "framing", `String framing
    ; "bytes", `Int write.bytes
    ; "sha256", `String write.sha256
    ; "fragments", fragments ]
;;

let report ~label observer receipt =
  try observer receipt with
  | exn when Keeper_operator_interrupt.is_operator_interrupt exn -> raise exn
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    Log.Runtime_agent.warn
      "%s context submission measurement unavailable after complete write: %s"
      label (Printexc.to_string exn)
;;
