module Message_layout = Masc_tui_message_layout
module Tui_decode = Masc.Tui_decode
module Terminal_text = Masc_tui_ansi.Terminal_text
module Text_block = Masc_tui_text_block

(* The field is one wider than the longest label ("reviewed:") so every value
   keeps one gap after its colon. *)

type tone =
  | Proven
  | Refused
  | Waiting
  | Unreadable
  | Note
  | Quiet
  (* The plain foreground: the rows the operator actually reads to decide --
     the goal's promise and the evidence. Louder than the dim provenance,
     quieter than the warn instruction, so a confirmation block keeps three
     readable volumes instead of one flat shout. *)
  | Plain
  | Heading

type line =
  { tone : tone
  ; text : string
  }

(* Every row this module wraps is wire text: a judge's reason, a keeper's
   note, a timeline event, a store error. It is split on LF first and each
   line escaped on its own, so a control byte reaches the pane as its escape
   while a line break stays a new row instead of a printed "\x0A". A CRLF
   line ending loses its CR here too, or every row would end in "\x0D". *)
let without_line_end_cr line =
  let length = String.length line in
  if length > 0 && Char.equal line.[length - 1] '\r'
  then String.sub line 0 (length - 1)
  else line

let wrapped_indent ~width ~indent tone text =
  String.split_on_char '\n' text
  |> List.concat_map (fun line ->
       Message_layout.wrap_words ~max_cells:(max 1 (width - indent))
         (Masc.Tui_terminal_text.sanitize_terminal_text (without_line_end_cr line)))
  |> List.map (fun row -> { tone; text = String.make indent ' ' ^ row })

let wrapped ~width tone text = wrapped_indent ~width ~indent:0 tone text

(* [Yojson] reads the value once, to decide that it is JSON; the layout below
   never re-reads it. Re-serialising the parsed value is not faithful enough
   for evidence: this yojson (2.6.0) reads [1E400] as float infinity and
   writes back the non-JSON word "Infinity", and it normalises [1.50] to
   [1.5] -- the reader would see a different number than the wire carried.
   So the display is the validated original substring with whitespace
   inserted between tokens and nothing else: every string and number byte,
   including its literal spelling, is copied as it arrived. On Yojson-valid
   input a token run cannot bleed past its end -- after a number only
   [,],}] or whitespace can follow, and [e],[E],[+],[-] inside the run occur
   only within a number. *)
let layout_validated_json (raw : string) : string =
  let out = Buffer.create (String.length raw + 64) in
  let depth = ref 0 in
  let fresh_line = ref true in
  let mark_written () = fresh_line := false in
  let break_line () =
    if not !fresh_line then begin
      Buffer.add_char out '\n';
      for _ = 1 to !depth do Buffer.add_string out "  " done;
      fresh_line := true
    end in
  let at = ref 0 in
  let length = String.length raw in
  let copy_char () = Buffer.add_char out raw.[!at]; incr at; mark_written () in
  let copy_while predicate =
    while !at < length && predicate raw.[!at] do copy_char () done in
  let copy_string () =
    (* the opening quote *)
    copy_char ();
    let escaped = ref false in
    let continue = ref true in
    while !continue && !at < length do
      let char = raw.[!at] in
      copy_char ();
      if !escaped then escaped := false
      else if Char.equal char '\\' then escaped := true
      else if Char.equal char '"' then continue := false
    done in
  let copy_number () =
    copy_while (fun char ->
        (Char.equal char '-')
        || (Char.equal char '+')
        || (Char.equal char '.')
        || (Char.equal char 'e')
        || (Char.equal char 'E')
        || (char >= '0' && char <= '9')) in
  let copy_word () = copy_while (fun char -> char >= 'a' && char <= 'z') in
  let open_container close =
    (* peek past the brace for an empty pair, which stays inline *)
    let probe = ref (!at + 1) in
    while !probe < length && (Char.equal raw.[!probe] ' ' || Char.equal raw.[!probe] '\t'
                              || Char.equal raw.[!probe] '\n' || Char.equal raw.[!probe] '\r')
    do incr probe done;
    if !probe < length && Char.equal raw.[!probe] close then begin
      copy_char ();
      copy_char ()
    end else begin
      copy_char ();
      incr depth;
      break_line ()
    end in
  while !at < length do
    (match raw.[!at] with
     | ' ' | '\t' | '\n' | '\r' -> incr at
     | '{' -> open_container '}'
     | '[' -> open_container ']'
     | '}' | ']' ->
         decr depth;
         break_line ();
         copy_char ()
     | ',' ->
         copy_char ();
         break_line ()
     | ':' ->
         copy_char ();
         Buffer.add_char out ' ';
         mark_written ()
     | '"' -> copy_string ()
     | '0' .. '9' | '-' -> copy_number ()
     | 'a' .. 'z' -> copy_word ()
     | _ -> copy_char ())
  done;
  Buffer.contents out

(* A summary sometimes carries a whole JSON value -- a keeper's failed turn
   names its cause that way. Kept inside the sentence it is one long line the
   terminal wraps mid-token; laid out one member per line the reader sees the
   fields instead of the punctuation. Yojson is the arbiter of what is JSON:
   the value must parse either to the end of the summary or from the first
   brace to the last when prose follows it. A cause the server previews to a
   byte prefix does not parse and stays the sentence it arrived in, rather
   than a half-tree that reads as decided. Answers (text before the value,
   the value re-laid-out verbatim, text after it). *)
let split_embedded_json (text : string) : (string * string * string) option =
  match String.index_opt text '{' with
  | None -> None
  | Some start ->
      let attempt stop =
        match
          Yojson.Safe.from_string (String.sub text start (stop - start))
        with
        | exception Yojson.Json_error _ -> None
        | (`Assoc _ | `List _) ->
            let raw = String.sub text start (stop - start) in
            Some
              ( String.sub text 0 start
              , layout_validated_json raw
              , String.sub text stop (String.length text - stop) )
        | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Null -> None
      in
      (match attempt (String.length text) with
       | Some split -> Some split
       | None -> (
           match String.rindex_opt text '}' with
           | Some stop when stop + 1 > start -> attempt (stop + 1)
           | _ -> None))

(* The confirmation read answers with the metadata projection of each
   submitted original, not the originals: identity and size reach the
   operator, with the file digest for a binary original, while contents stay
   on the server. Each kind is parsed into its own shape, and a kind this
   build does not know keeps its name on screen instead of disappearing -- a
   newer server can add one without stranding an older reader
   mid-confirmation. *)
type submitted_original =
  | Original_collaboration of { reference : string; bytes : int }
  | Original_note of { bytes : int }
  | Original_artifact of { reference : string; bytes : int; truncated : bool }
  | Original_binary of { reference : string; bytes : int; sha256 : string; format : string }
  | Original_unreadable of { reference : string option; reason : string }
  | Original_unknown of string

type confirmation_workspace = {
  base_path : Tui_decode.Canonical_path.t;
  masc_root : Tui_decode.Canonical_path.t;
}

let confirmation_workspace_of_identity (identity : Tui_decode.server_identity) = {
  base_path = identity.sid_base_path;
  masc_root = identity.sid_masc_root;
}

let same_confirmation_workspace (left : confirmation_workspace) (right : confirmation_workspace) =
  Tui_decode.Canonical_path.equal left.base_path right.base_path
  && Tui_decode.Canonical_path.equal left.masc_root right.masc_root

type confirmation = {
  goal_id : string;
  phase : Goal_phase.t;
  verdict : Goal_verification.verdict;
  recorded_confirmation : Goal_verification.confirmation option;
  submitted : submitted_original list;
  workspace : confirmation_workspace;
  inspection_operator_id : string;
  runtime_instance_id : string;
  credential_headers : (string * string) list;
  credential_owner : unit ref;
}

type receipt_authority = {
  ra_workspace : confirmation_workspace;
  ra_operator_id : string;
  ra_runtime_instance_id : string;
  ra_credential_owner : unit ref;
}

let confirmation_receipt_authority (confirmation : confirmation) = {
  ra_workspace = confirmation.workspace;
  ra_operator_id = confirmation.inspection_operator_id;
  ra_runtime_instance_id = confirmation.runtime_instance_id;
  ra_credential_owner = confirmation.credential_owner;
}

(* Every field of a metadata item that is present is also well-formed: a
   present-but-broken item fails the read, because the projection is written
   by the same server that wrote the proof. *)
let decode_submitted_original (item : Yojson.Safe.t) : (submitted_original, string) result =
  let ( let* ) = Result.bind in
  let field name = function
    | `Assoc fields ->
        (match List.assoc_opt name fields with
         | Some value -> Ok value
         | None -> Error ("submitted evidence: missing " ^ name))
    | _ -> Error "submitted evidence: expected an object"
  in
  let string name = function
    | `String value -> Ok value
    | _ -> Error ("submitted evidence: " ^ name ^ " is not a string")
  in
  let int name = function
    | `Int value -> Ok value
    | _ -> Error ("submitted evidence: " ^ name ^ " is not an integer")
  in
  let bool name = function
    | `Bool value -> Ok value
    | _ -> Error ("submitted evidence: " ^ name ^ " is not a boolean")
  in
  let* kind = let* value = field "kind" item in string "kind" value in
  match kind with
  | "collaboration" ->
      let* reference = (let* value = field "reference" item in string "reference" value) in
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      Ok (Original_collaboration { reference; bytes })
  | "note" ->
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      Ok (Original_note { bytes })
  | "artifact" ->
      let* reference = (let* value = field "reference" item in string "reference" value) in
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      let* truncated = (let* value = field "truncated" item in bool "truncated" value) in
      Ok (Original_artifact { reference; bytes; truncated })
  | "artifact_binary" ->
      let* reference = (let* value = field "reference" item in string "reference" value) in
      let* bytes = (let* value = field "bytes" item in int "bytes" value) in
      let* sha256 = (let* value = field "sha256" item in string "sha256" value) in
      let* format = (let* value = field "format" item in string "format" value) in
      Ok (Original_binary { reference; bytes; sha256; format })
  | "artifact_unreadable" ->
      let* reason = let* value = field "reason" item in string "reason" value in
      let reference =
        match item with
        | `Assoc fields ->
            (match List.assoc_opt "reference" fields with
             | Some (`String reference) -> Some reference
             | _ -> None)
        | _ -> None
      in
      Ok (Original_unreadable { reference; reason })
  | other -> Ok (Original_unknown other)

type confirmation_read_error =
  | Read_failed of unit ref option * string
  | Read_http_error of unit ref * int
  | Server_changed of unit ref

type confirmation_read = (string, confirmation, confirmation_read_error) Masc_tui_fetched.source

type confirmation_state =
  | Inspecting of confirmation_read
  (* Keep the read generation while the write is in flight. Navigation can
     cancel inspection, but cannot cancel a confirmation already sent. *)
  | Submitting of string * confirmation_read

let confirmation_read_error_message ~ko ~credential_is_current =
  let text korean english = if ko then korean else english in function
  | Read_failed (Some owner, _) when credential_is_current owner -> (text "목표 확인 증거 조회 실패 · 연결과 권한을 확인하세요" "Goal confirmation read failed; check the connection and permissions")
  | Read_failed (Some _, _) -> (text "인증 정보가 바뀌었습니다 · 증거를 다시 조회하세요" "Goal confirmation credential changed; read the proof again")
  | Read_failed (None, _) -> (text "목표 확인 증거를 조회할 수 없습니다 · 다시 조회하세요" "Goal confirmation read unavailable; read the proof again")
  | Read_http_error (owner, 503) when credential_is_current owner ->
      (text "목표 확인 증거 조회 불가 (HTTP 503) · 서버·저장소·런타임을 확인하세요" "Goal confirmation unavailable (HTTP 503); check server availability, storage and runtime")
  | Read_http_error (owner, status) when credential_is_current owner -> Printf.sprintf (if ko then "목표 확인 증거 조회 실패 (HTTP %d)" else "Goal confirmation read failed (HTTP %d)") status
  | Read_http_error _ -> (text "인증 정보가 바뀌었습니다 · 증거를 다시 조회하세요" "Goal confirmation credential changed; read the proof again")
  | Server_changed owner when credential_is_current owner -> (text "서버가 바뀌었습니다 · 서버 식별 재확인 중" "Goal confirmation server changed; rechecking server identity")
  | Server_changed _ -> (text "인증 정보가 바뀌었습니다 · 증거를 다시 조회하세요" "Goal confirmation credential changed; read the proof again")

let suspend_confirmation_read read =
  let read = match Masc_tui_fetched.current_key read with
    | None -> read
    | Some key ->
        (match Masc_tui_fetched.start ~equal:String.equal read ~key with
         | Already_loading -> read
         | Started (reading, _) -> reading) in
  Masc_tui_fetched.suspend_with ~reason:(Read_failed (None, "Reading suspended; waiting for workspace identity.")) read

let confirmation_view_for read ~goal_id =
  if Masc_tui_fetched.in_flight read && Masc_tui_fetched.current_key read = Some goal_id
  then Masc_tui_fetched.Loading
  else Masc_tui_fetched.view_for ~equal:String.equal read ~key:goal_id

let decode_confirmation ~goal_id ~workspace ~runtime_instance_id ~credential_headers ~credential_owner json =
  let open Result.Syntax in
  let field name = function
    | `Assoc fields ->
        (match List.assoc_opt name fields with
         | Some value -> Ok value
         | None -> Error ("goal confirmation: missing " ^ name))
    | _ -> Error "goal confirmation: expected object"
  in
  let* goal = field "goal" json in
  let* inspection_operator = field "inspection_operator_id" json in
  let* inspection_operator_id = match inspection_operator with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error "goal confirmation: missing inspection operator" in
  let* id = field "id" goal in
  let* verification = field "verification" json in
  let* proof_goal = field "goal_id" verification in
  let* () =
    if id = `String goal_id && proof_goal = `String goal_id then Ok ()
    else Error "goal confirmation: goal identity mismatch"
  in
  let* phase = Goal_phase.of_fields goal in
  let* completion = field "completion" verification in
  let* completion = Goal_verification.completion_state_of_yojson completion in
  let* verdict, recorded_confirmation =
    match phase, completion with
    | Goal_phase.Awaiting_confirmation, Goal_verification.Proof_proven verdict -> Ok (verdict, None)
    (* The server records a confirmation before it runs the caller's step and
       saves the phase. When that step refuses, or the phase cannot be saved,
       the goal stays here with the confirmation recorded, and confirming again
       is how the operator finishes it. *)
    | Goal_phase.Awaiting_confirmation, Goal_verification.Human_confirmed (verdict, recorded)
    | Goal_phase.Completed, Goal_verification.Human_confirmed (verdict, recorded) -> Ok (verdict, Some recorded)
    | (Goal_phase.Awaiting_confirmation, (Goal_verification.Completion_idle | (Goal_verification.Proof_pending _ | Goal_verification.Proof_refuted _)))
    | (Goal_phase.Completed, (Goal_verification.Completion_idle | (Goal_verification.Proof_pending _ | (Goal_verification.Proof_proven _ | Goal_verification.Proof_refuted _))))
    | ((Goal_phase.Executing | (Goal_phase.Verifying | (Goal_phase.Dropped | (Goal_phase.Paused _ | Goal_phase.Blocked _)))), _) -> Error "goal confirmation: no current proven completion to confirm"
  in
  let* revision = field "criterion_revision" goal in
  let* title = field "title" goal in
  let* metric = field "metric" goal in
  let* target = field "target_value" goal in
  let* criterion = Goal_store.criterion_of_yojson
      (`Assoc ["revision", revision; "title", title; "metric", metric; "target_value", target]) in
  if Goal_store.criterion_equal criterion verdict.criterion then
    let submitted =
      (* An answer from before the list existed carries no key; the originals
         then simply do not draw. *)
      match verification with
      | `Assoc fields ->
          (match List.assoc_opt "submitted_evidence" fields with
           | None -> Ok []
           | Some (`List items) ->
               let rec all acc = function
                 | [] -> Ok (List.rev acc)
                 | item :: rest ->
                     (match decode_submitted_original item with
                      | Ok original -> all (original :: acc) rest
                      | Error detail -> Error detail)
               in
               all [] items
           | Some _ -> Error "submitted evidence: expected a list")
      | _ -> Error "goal confirmation: expected object"
    in
    let ( let* ) = Result.bind in
    let* submitted = submitted in
    Ok { goal_id; phase; verdict; recorded_confirmation; submitted; workspace; inspection_operator_id; runtime_instance_id; credential_headers; credential_owner }
  else Error "goal confirmation: criterion mismatch"

let confirmation_body { goal_id; verdict; workspace; inspection_operator_id; runtime_instance_id; _ } =
  let Goal_store.Criterion criterion = verdict.Goal_verification.criterion in
  `Assoc
    [ "goal_id", `String goal_id
    ; "criterion_revision", `String criterion.revision
    ; "request_id", `String verdict.request_id
    ; "verification_run_id", `String verdict.verification_run_id
    ; "expected_operator_id", `String inspection_operator_id
    ; "expected_runtime_instance_id", `String runtime_instance_id
    ; "expected_workspace", `Assoc
        [ "base_path", `String (Tui_decode.Canonical_path.to_string workspace.base_path)
        ; "masc_root", `String (Tui_decode.Canonical_path.to_string workspace.masc_root) ]
    ]

let same_confirmation_binding left right =
  String.equal left.goal_id right.goal_id
  && same_confirmation_workspace left.workspace right.workspace
  && String.equal left.inspection_operator_id right.inspection_operator_id
  && String.equal left.runtime_instance_id right.runtime_instance_id
  && left.credential_headers = right.credential_headers
  && left.credential_owner == right.credential_owner
  && left.verdict = right.verdict

let same_recorded_confirmation left right =
  match left.recorded_confirmation, right.recorded_confirmation with
  | Some first, Some second -> first = second
  | None, _ | _, None -> false

let receipt_authority_current ~credential_current ~current_instance ~current_confirmation ~(receipt : receipt_authority) =
  credential_current && current_instance = Some receipt.ra_runtime_instance_id
  && match current_confirmation with
  | None -> false
  | Some (confirmation : confirmation) ->
      same_confirmation_workspace confirmation.workspace receipt.ra_workspace
      && String.equal confirmation.inspection_operator_id receipt.ra_operator_id
      && String.equal confirmation.runtime_instance_id receipt.ra_runtime_instance_id
      && confirmation.credential_owner == receipt.ra_credential_owner

let receipt_outcome_text ~ko ~current result =
  let text korean english = if ko then korean else english in
  (* The receipt is bound to a server instance, a workspace and an operator
     ([receipt_authority_current]); any of the three may have moved. *)
  let reinspect =
    let workspace = Masc_tui_words.workspace_name ~ko in
    text ("원래 서버, " ^ workspace ^ ", 운영자를 다시 확인")
      ("reinspect the original server, " ^ workspace ^ " and operator") in
  match current, result with
  | false, Error _ -> text "결과 미확인" "Outcome unconfirmed" ^ " · " ^ reinspect
  | false, Ok _ -> text "응답 보존됨" "Response retained" ^ " · " ^ reinspect
  | true, Ok message -> text "응답: " "Response: " ^ Terminal_text.single_line message
  | true, Error error -> text "오류: " "Error: " ^ Terminal_text.single_line error

(* The confirmation block is one decision the operator reads in layers: what
   to do, what the goal promised, which proof binding is on the table, and
   the evidence itself. It used to be one flat warn-coloured list, so the
   instruction, the ids and the evidence all spoke at the same volume and the
   pane gave the eye nowhere to land. Each layer now keeps its own tone --
   warn for the instruction, plain for what is read, dim for the binding fine
   print -- and the evidence stays the last group, so a presented frame still
   proves the operator scrolled through the whole proof. *)
(* The originals are provenance the operator may open, so they read at the
   same plain volume as the evidence, as one labelled list under it. The list
   ends the block when present, which keeps the presented-frame receipt
   meaning "the end of the block". Shown sha length is a presentation choice
   (board question pending); the full value stays one action away. *)
let sha256_cells = 12

let humanized_bytes bytes =
  let kb = 1024 and mb = 1024 * 1024 in
  if bytes >= mb then Printf.sprintf "%.1f MB" (float_of_int bytes /. float_of_int mb)
  else if bytes >= kb then Printf.sprintf "%.1f KB" (float_of_int bytes /. float_of_int kb)
  else Printf.sprintf "%d B" bytes

let sha256_prefix sha256 =
  String.sub sha256 0 (min (String.length sha256) sha256_cells)

let submitted_original_text ~ko (original : submitted_original) =
  let text korean english = if ko then korean else english in
  match original with
  | Original_collaboration { reference; bytes } ->
      Printf.sprintf (if ko then "협업 원본 %s · %s" else "collaboration %s · %s") reference (humanized_bytes bytes)
  | Original_note { bytes } ->
      Printf.sprintf (if ko then "메모 · %s" else "note · %s") (humanized_bytes bytes)
  | Original_artifact { reference; bytes; truncated } ->
      Printf.sprintf (if ko then "자료 %s · %s%s" else "artifact %s · %s%s") reference (humanized_bytes bytes)
        (if truncated then (text " · 일부만 보존" " · truncated") else "")
  | Original_binary { reference; bytes; sha256; format } ->
      Printf.sprintf (if ko then "파일 %s · %s · %s · sha256 %s" else "binary %s · %s · %s · sha256 %s")
        reference format (humanized_bytes bytes) (sha256_prefix sha256)
  | Original_unreadable { reference; reason } ->
      (match reference with
       | Some reference -> (text "읽기 실패 " "unreadable ") ^ reference
       | None -> (text "읽기 실패" "unreadable"))
      ^ " · " ^ reason
  | Original_unknown kind -> (text "알 수 없는 종류 " "unknown kind ") ^ kind

let confirmation_lines ~width ~ko { goal_id; phase; verdict; recorded_confirmation; submitted; _ } =
  let Goal_store.Criterion criterion = verdict.Goal_verification.criterion in
  let text korean english = if ko then korean else english in
  let line_of tone text = { tone; text } in
  let cells = List.fold_left (fun widest label -> max widest (Message_layout.display_width label + 2)) 0
    (if ko then ["제목"; "목표값"; "결속"; "확인"; "제출 원본"]
     else ["Title"; "Target"; "Binding"; "Confirmed"; "Submitted"]) in
  let prefix label = let label = label ^ ":" in
    label ^ String.make (max 0 (cells - Message_layout.display_width label)) ' ' in
  let sanitize text =
    Masc.Tui_terminal_text.sanitize_terminal_text (without_line_end_cr text)
  in
  (* Align continuation rows by terminal cells in the selected language. *)
  let labelled ~tone label text =
    let lead = prefix label in
    String.split_on_char '\n' text
    |> List.concat_map (fun text ->
         Message_layout.wrap_words ~max_cells:(max 1 (width - cells))
           (sanitize text))
    |> List.mapi (fun index text ->
         line_of tone ((if index = 0 then lead else String.make cells ' ') ^ text))
  in
  let paragraph ~indent tone text =
    String.split_on_char '\n' text
    |> List.concat_map (fun text ->
         Message_layout.wrap_words ~max_cells:(max 1 (width - indent))
           (sanitize text))
    |> List.map (fun text -> line_of tone (String.make indent ' ' ^ text))
  in
  let header =
    line_of Note (match phase with
      | Goal_phase.Completed -> if ko then "[ 확인 완료 ]" else "[ Confirmation recorded ]"
      | Goal_phase.(Executing | Verifying | Awaiting_confirmation | Dropped | Paused _ | Blocked _) ->
        if ko then "[ 판정 확인 ]" else "[ Confirm the proof ]")
  in
  let instruction =
    paragraph ~indent:0 Waiting
      (match phase with
       | Goal_phase.Completed -> if ko then "저장된 확인을 조회했습니다. 추가 요청은 보내지 않습니다."
         else "Recorded confirmation inspected. No additional request will be sent."
       | Goal_phase.(Executing | Verifying | Awaiting_confirmation | Dropped | Paused _ | Blocked _) ->
         match recorded_confirmation with
         | Some _ -> if ko
           then "저장된 확인과 증거를 끝까지 읽고 [a]를 눌러 완료 처리를 재개합니다. Esc는 취소합니다."
           else "Read the recorded confirmation and evidence, then [a] to resume completion; Esc cancels."
         | None -> if ko
           then "이 증명을 확인합니다 — 증거를 끝까지 읽은 뒤 [a], 그만두려면 Esc"
           else "CONFIRM THIS PROOF — read through evidence, then [a]; Esc cancels")
  in
  let promise =
    labelled ~tone:Plain (text "제목" "Title") criterion.title
    @ labelled ~tone:Plain (text "목표값" "Target")
        (Option.value criterion.metric ~default:(text "미지정" "not declared")
         ^ " = " ^ Option.value criterion.target_value ~default:(text "미지정" "not declared"))
  in
  let binding =
    labelled ~tone:Quiet (text "결속" "Binding")
      (Printf.sprintf (if ko then "목표 %s · 기준 %s · 요청 %s · 검증 실행 %s" else "goal %s · criterion %s · request %s · verifier run %s")
         goal_id criterion.revision verdict.request_id
         verdict.verification_run_id)
  in
  let recorded = match recorded_confirmation with
    | None -> []
    | Some (recorded : Goal_verification.confirmation) ->
        labelled ~tone:Note (text "확인" "Confirmed") (recorded.operator_id ^ " · " ^ recorded.confirmed_at)
        @ (if phase = Goal_phase.Completed then [] else
          paragraph ~indent:0 Waiting (if ko
            then "운영자 확인은 저장되었습니다. 목표 완료와 후속 처리는 아직 확인되지 않았습니다."
            else "Operator confirmation is recorded; Goal completion and follow-up are not yet verified.")) in
  let evidence =
    line_of Plain (text "근거:" "Evidence:") :: paragraph ~indent:2 Plain verdict.evidence
  in
  let submitted =
    match submitted with
    | [] -> []
    | originals ->
        List.concat_map
          (fun original ->
             Message_layout.wrap_words ~max_cells:(max 1 (width - cells))
               (submitted_original_text ~ko original))
          originals
        |> List.mapi (fun index line ->
               line_of Plain
                 ((if index = 0 then prefix (text "제출 원본" "Submitted") else String.make cells ' ')
                  ^ line))
  in
  let blank = [ line_of Quiet "" ] in
  let coverage =
    if phase = Goal_phase.Awaiting_confirmation then
      blank
      @ paragraph ~indent:0 Quiet (if ko
          then "Candle 후보는 증명 기록 중 저장된 Snapshot의 연결 작업만 사용합니다."
          else "Candle candidates use the links in the Snapshot saved during proof recording.")
      @ paragraph ~indent:0 Quiet (if ko
          then "지급 누락 여부: 미확인" else "Missing contributions: unknown.")
    else [] in
  header
  :: (instruction @ (if recorded = [] then [] else blank @ recorded) @ blank @ promise @ blank @ binding
      @ coverage @ blank @ evidence @ (match submitted with [] -> [] | _ -> blank @ submitted))

(* A verdict is a headline and, when the judge left one, the measurement it
   rests on. They are separate rows because the reason wraps and the headline
   should stay findable at the top of the block. *)
let verdict ~width tone headline reason =
  { tone; text = headline }
  :: (match reason with
      | None -> []
      | Some reason -> wrapped ~width tone reason)

(* The latest verifier scan could not settle this goal, so the judge's last
   word is not what holds it: no judge model runs in these steps, only
   original, goal store and ledger access. The heading says which step failed;
   the store's reason wraps under it like a verdict's. *)
let unreconciled_heading ~ko =
  let text korean english = if ko then korean else english in function
  | Goal_reconcile_step.Reconcile_proof -> (text "검증기가 확정 근거를 적용하지 못함" "verifier could not apply the committed proof")
  | Goal_reconcile_step.Rearm_proof -> (text "검증기가 증명 요청을 확인하지 못함" "verifier could not resolve the proof request")
  | Goal_reconcile_step.Read_original -> (text "검증기가 보존된 요청을 읽지 못함" "verifier could not read the retained request")

(* [c] on a Verifying goal sends [request_complete] again: under the goal lock
   it applies a committed proof or retries the matching pending request. An
   unavailable binding cannot establish that an older review ended. [o]
   reopens the goal, which archives
   a committed proof, so it is offered as taking the goal back, never as the
   way to unstick it. *)
let verifying_next_step ~ko ~can_retry unreconciled =
  let text korean english = if ko then korean else english in
  if not can_retry then
    ( Unreadable
    , (text "검증 결속 미확인 · 기존 검토가 진행 중일 수 있습니다. 연결·저장소·런타임을 확인하고 [r]로 재조회하세요. [x]:중단 요청" "verification binding unavailable - a prior review may still run; check connection, server storage and runtime, then [r] refresh; [x] requests drop") )
  else match unreconciled with
  | Some (_ : Tui_decode.verifier_unreconciled) ->
    ( Refused
    , (text "검증 결과 반영 실패 · [c]:복구 요청 · [o]:다시 열기 요청 · [x]:중단 요청" "the verifier could not settle it - [c] requests recovery; [o] takes it back, [x] drops it") )
  | None ->
    ( Waiting
    , (text "검증 미해결 · [c]:복구 요청 · [o]:다시 열기 요청 · [x]:중단 요청" "verification unresolved - [c] requests recovery; [o] takes it back, [x] drops it") )

let unreconciled_lines ~ko ~width (blocked : Tui_decode.verifier_unreconciled) =
  verdict ~width:(max 1 width) Refused (unreconciled_heading ~ko blocked.vu_step)
    (Some blocked.vu_detail)

let note ~ko ~width = function
  | None -> []
  | Some note -> { tone = Note; text = (if ko then "메모" else "note") } :: wrapped ~width Note note

let body ~ko ~width proof last_review_note =
  let text korean english = if ko then korean else english in
  let width = max 1 width in
  match (proof : Tui_decode.goal_proof) with
  | Tui_decode.Proof_proven reason ->
      verdict ~width Proven (text "검증 통과" "proven") reason @ note ~ko ~width last_review_note
  | Tui_decode.Proof_refuted reason ->
      verdict ~width Refused (text "검증 거절" "refused") reason @ note ~ko ~width last_review_note
  | Tui_decode.Proof_pending ->
      { tone = Waiting; text = (text "완료 판정 대기" "verification result pending") }
      :: note ~ko ~width last_review_note
  | Tui_decode.Proof_stale evidence ->
      verdict ~width Note (text "기준 변경 · 이전 근거는 기록으로 보존됨" "criterion changed; previous proof is historical") evidence
      @ note ~ko ~width last_review_note
  | Tui_decode.Proof_unreadable detail ->
      verdict ~width Unreadable (text "검증 기록 읽기 실패" "verification ledger unreadable") detail
      @ note ~ko ~width last_review_note
  | Tui_decode.Proof_idle ->
      (match note ~ko ~width last_review_note with
       | [] -> [ { tone = Quiet; text = (text "판정 미기록" "no verdict on the ledger") } ]
       | rows -> { tone = Quiet; text = (text "판정 미기록" "no verdict on the ledger") } :: rows)

let criterion_review_lines ~width ~ko review =
  let text korean english = if ko then korean else english in
  let scope = wrapped ~width Note
    (text "성공 기준의 실재성과 도달 가능성에 대한 검토입니다. 완료 증명과 사람의 최종 확인은 별도입니다."
      "Criterion feasibility review; completion proof and human confirmation remain separate.") in
  let rows = match (review : Tui_decode.goal_criterion_review) with
    | Tui_decode.Criterion_unchecked ->
      verdict ~width Quiet (text "성공 기준 검토 미기록" "Criterion review not recorded") None
    | Tui_decode.Criterion_unavailable detail ->
      verdict ~width Unreadable (text "성공 기준 검토 확인 불가" "Criterion review unavailable") (Some detail)
    | Tui_decode.Criterion_observed observed ->
      let tone, headline, reason = match observed.state with
        | Tui_decode.Criterion_pending -> Waiting, text "성공 기준 검토 대기" "Criterion review pending", observed.detail
        | Tui_decode.Criterion_execution_pending -> Waiting, text "성공 기준 검토 실행 중" "Criterion review executing", observed.detail
        | Tui_decode.Criterion_execution_unknown -> Unreadable, text "기준 검토 실행 결과 불확실" "Criterion review execution unknown", observed.detail
        | Tui_decode.Criterion_judgment_pending -> Waiting, text "기준 판정 반영 대기" "Criterion judgment pending publication", observed.detail
        | Tui_decode.Criterion_deferred -> Waiting, text "성공 기준 검토 보류" "Criterion review deferred", observed.detail
        | Tui_decode.Criterion_viable reason -> Note, text "도달 가능한 성공 기준" "Criterion is viable", Some reason
        | Tui_decode.Criterion_needs_revision reason -> Refused, text "성공 기준 수정 필요" "Criterion needs revision", Some reason
        | Tui_decode.Criterion_superseded -> Quiet, text "기준 검토 대체됨" "Criterion review superseded", observed.detail in
      verdict ~width tone headline reason
      @ wrapped ~width Quiet (text "기준 버전: " "Criterion revision: " ^ observed.criterion_revision)
      @ wrapped ~width Quiet (text "검토 요청: " "Review request: " ^ observed.request_id) in
  rows @ scope

(* The task-history shape. The goal timeline rows read [event_stamp] below. *)
let short_ts ts =
  if String.length ts >= 16 then
    String.sub ts 5 5 ^ " " ^ String.sub ts 11 5
  else ts

(* The stamp a timeline row leads with, in the operator's time zone. The
   seconds stay, because one goal's evening holds events a minute apart and
   their order is the story; the date goes when the event is today's.

   The stamp was cut out of the source text by position, so it showed the
   server's UTC clock with nothing saying so, nine hours off the clocks on
   the other screens. A value that does not parse as a timestamp is shown
   whole rather than guessed at: its zone is not known, so it is not moved
   into ours. *)
module Instant = Masc_tui_value.Instant

let event_stamp_precision = Instant.To_second

let event_stamp ~now (ts : string) =
  match Masc_domain.parse_iso8601_opt ts with
  | Some at ->
      (* Right-aligned in the widest stamp, so the subjects of a day's rows
         and of an older day's start in one column. *)
      Printf.sprintf "%*s"
        (Instant.cell_width event_stamp_precision)
        (Instant.cell_text event_stamp_precision ~now at)
  | None -> ts

let moment_text ~now (ts : string) =
  match Masc_domain.parse_iso8601_opt ts with
  | Some at -> Instant.detail_text Instant.To_minute ~now at
  | None -> ts

let severity_tone = function
  | "ok" -> Quiet
  | "warn" -> Waiting
  | "bad" -> Refused
  | _ -> Note

(* Which thing the row is about, and what it is.

   The server sends six fields and the pane drew two of them -- the kind and
   the summary -- so a goal with thirteen task rows drew "task  todo" thirteen
   times. The id and the title were in the payload the whole time.

   [lane] is the typed reference ("task:task-1013", "approval:appr-...",
   "keeper:<name>", "goal"). Its id half is the subject where it has one; a
   lane with no id is a goal's own event, and there the kind is what names it,
   so that is what the column keeps rather than the bare word "goal". *)
let subject (event : Tui_decode.goal_timeline_event) =
  match String.index_opt event.gt_lane ':' with
  | Some index ->
      String.sub event.gt_lane (index + 1)
        (String.length event.gt_lane - index - 1)
  | None -> event.gt_kind

(* A keeper row's title arrives as "<keeper> · <event title>" while the
   subject column beside it already names the keeper, so the leading
   repetition goes. Both joins are tried exactly -- the one the server
   spells and the one this pane spells -- and a title that carries neither
   keeps every word. *)
let strip_subject ~subject title =
  List.fold_left
    (fun title prefix ->
       let length = String.length prefix in
       if String.length title > length
          && String.equal (String.sub title 0 length) prefix
       then String.sub title length (String.length title - length)
       else title)
    title [ subject ^ " \xc2\xb7 "; subject ^ "  \xc2\xb7 " ]

(* Title first, state after: the title names the row and the summary qualifies
   it. A task's summary is its status ("todo"), an approval's is its input
   preview, a keeper's is its event summary -- none of them identify the row on
   their own, which is why the pane read as a list of statuses with nothing
   attached. A summary that only repeats the title adds nothing and is
   dropped, and so is one that repeats the subject column beside it: a goal's
   own creation event carries its kind in both, and the row read
   "goal_created  Goal Event \xc2\xb7 goal_created". The summary arrives
   pre-trimmed and may be only the sentence half of one that carried a JSON
   value, which [timeline] splits off before it gets here. *)
let headline ~subject ~title summary =
  let title = strip_subject ~subject title in
  let summary = if String.equal summary subject || String.equal summary title then "" else summary in
  if String.equal summary "" then title
  else if String.equal title "" then summary
  else title ^ "  \xc2\xb7 " ^ summary

(* The goal's merged event timeline, appended after [body] so it rides the
   same scroll. Loaded lazily on detail entry; every non-ready state says
   what it is instead of rendering as an empty history. *)
let timeline_unavailability_detail = function
  | Tui_decode.Goal_source_failure (Goal_store_unavailable view) ->
      "Cause: " ^ Tui_decode.goal_store_unavailable_view_to_string view
  | Tui_decode.Goal_source_failure (Goal_task_links_unavailable detail) ->
      "Linked tasks unavailable · Cause: " ^ detail
  | Tui_decode.Approval_queue_failure detail ->
      "Approval queue unavailable · Cause: " ^ detail

let timeline ~ko ~now ~width ~goal_id
    (loaded : (string, Tui_decode.goal_timeline_event list) Masc_tui_fetched.t) =
  let text korean english = if ko then korean else english in
  let header =
    { tone = Heading; text = (text "관련 기록 · 연결 항목별 마지막 상태" "RELATED ACTIVITY · latest state per linked item") }
  in
  (* One event, three volumes: a dim lead naming when it happened and to
     what, the severity-coloured sentence under it, and -- when the summary
     carried a JSON value -- the value's own structure one more step in, no
     louder than the sentence above it. Before this, the whole event was one
     wrapped paragraph: the timestamp and the subject and the cause ran
     together, a continuation line started at the pane's edge where it read
     as a row that lost its parent, and a JSON cause wrapped mid-token. *)
  let observed = function
        | [] ->
            [ { tone = Quiet; text = (text "  (기록 없음)" "  (no events recorded)") } ]
        | events ->
            List.concat_map
              (fun (event : Tui_decode.goal_timeline_event) ->
                let tone = severity_tone event.gt_severity in
                let subject = subject event in
                let lead =
                  wrapped ~width Quiet
                    (Printf.sprintf "  %s  %s" (event_stamp ~now event.gt_ts) subject) in
                let title = String.trim event.gt_title in
                let summary = String.trim event.gt_summary in
                let body =
                  match split_embedded_json summary with
                  | None ->
                      wrapped_indent ~width ~indent:4 tone
                        (headline ~subject ~title summary)
                  | Some (sentence, document, after) ->
                      wrapped_indent ~width ~indent:4 tone
                        (headline ~subject ~title sentence)
                      (* The value's own nesting is indentation, so it keeps
                         it: [preformatted_rows] wraps a long member without
                         flattening the levels above it. *)
                      @ (Text_block.preformatted_rows
                           ~max_cells:(max 1 (width - 6)) document
                         |> List.map (fun row ->
                             { tone = Note; text = "      " ^ row }))
                      @ (if String.equal (String.trim after) "" then []
                         else wrapped_indent ~width ~indent:6 Note after)
                in
                lead @ body)
              events
  in
  let view = Masc_tui_fetched.view_for ~equal:String.equal loaded ~key:goal_id in
  let rows =
    match view with
    | Masc_tui_fetched.Ready value -> observed value
    | Masc_tui_fetched.Stale (value, detail) ->
        wrapped ~width Unreadable
          ((text "  갱신 실패 · 이전 관측: " "  refresh failed; previous observation: ") ^ Terminal_text.single_line detail)
        @ observed value
    | Masc_tui_fetched.Failed detail -> wrapped ~width Unreadable
        ((text "  기록 조회 실패: " "  timeline load failed: ") ^ Terminal_text.single_line detail)
    | Masc_tui_fetched.Absent -> [ { tone = Quiet; text = (text "  기록 미조회" "  timeline not requested") } ]
    | Masc_tui_fetched.Loading -> [ { tone = Quiet; text = (text "  조회 중" "  loading...") } ]
  in
  let pending =
    if not (Masc_tui_fetched.in_flight loaded) then []
    else match view with
      | Masc_tui_fetched.Ready _ | Masc_tui_fetched.Stale _ ->
          [ { tone = Quiet; text = (text "  갱신 중 · 이전 관측" "  refreshing; previous observation") } ]
      | Masc_tui_fetched.Failed _ -> [ { tone = Quiet; text = (text "  재조회 중 · 이전 실패 유지" "  retrying; previous failure remains") } ]
      | Masc_tui_fetched.Absent | Masc_tui_fetched.Loading -> [] in
  ({ tone = Quiet; text = "" } :: header :: (pending @ rows))
