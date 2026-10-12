type unattributed = Existing_prefix | Separator
type kind = Block of Prompt_block_id.t | Unattributed of unattributed
type span =
  { kind : kind
  ; offset : int
  ; bytes : int
  ; sha256 : string
  }
type receipt =
  { bytes : int
  ; sha256 : string
  ; spans : span list
  }
type t =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  ; receipt : receipt option
  }

let sha256 text = Digestif.SHA256.(digest_string text |> to_hex)

let assemble ~existing_extra_system_context ~blocks =
  let buffer = Buffer.create 128 in
  let spans = ref [] in
  let present = ref false in
  let append kind text =
    spans :=
      { kind
      ; offset = Buffer.length buffer
      ; bytes = String.length text
      ; sha256 = sha256 text
      } :: !spans;
    Buffer.add_string buffer text
  in
  Option.iter
    (fun prefix ->
       present := true;
       append (Unattributed Existing_prefix) prefix)
    existing_extra_system_context;
  List.iter
    (fun (block, text) ->
       if !present then append (Unattributed Separator) "\n\n";
       append (Block block) text;
       present := true)
    blocks;
  if not !present then { extra_system_context = None; blocks; receipt = None }
  else
    let text = Buffer.contents buffer in
    { extra_system_context = Some text
    ; blocks
    ; receipt =
        Some { bytes = String.length text; sha256 = sha256 text; spans = List.rev !spans }
    }
;;

let blocks_for_carrier assembly text =
  let rec unique_blocks seen = function
    | [] -> true
    | (block, _) :: rest ->
      not (List.exists (Prompt_block_id.equal block) seen)
      && unique_blocks (block :: seen) rest
  in
  match assembly.extra_system_context, assembly.receipt with
  | Some issued, Some receipt
    when String.equal issued text
         && unique_blocks [] assembly.blocks
         && not
              (List.exists
                 (fun (span : span) ->
                    match span.kind with
                    | Unattributed Existing_prefix -> true
                    | Block _ | Unattributed Separator -> false)
                 receipt.spans) -> Some assembly.blocks
  | Some _, Some _ | Some _, None | None, _ -> None
;;

let receipt_to_json (receipt : receipt) =
  let span_to_json (span : span) =
    let kind =
      match span.kind with
      | Block block ->
        `Assoc [ "kind", `String "block"; "block", `String (Prompt_block_id.to_string block) ]
      | Unattributed reason ->
        `Assoc
          [ "kind", `String "unattributed"
          ; "reason", `String (match reason with Existing_prefix -> "existing_prefix" | Separator -> "separator")
          ]
    in
    `Assoc
      [ "source", kind
      ; "offset", `Int span.offset
      ; "bytes", `Int span.bytes
      ; "sha256", `String span.sha256
      ]
  in
  `Assoc
    [ "schema", `String "masc.logical-context-partition.v1"
    ; "scope", `String "assembled_raw_utf8_before_message_or_ipc_encoding"
    ; "bytes", `Int receipt.bytes
    ; "sha256", `String receipt.sha256
    ; "spans", `List (List.map span_to_json receipt.spans)
    ]
;;
