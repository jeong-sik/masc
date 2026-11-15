module Precondition = Masc.Request_workspace_precondition
module Canonical_path = Masc.Tui_decode.Canonical_path

type refusal = Precondition.refusal

(* What the scope's requests met so far. A request that got anything but a
   precondition refusal, or no answer at all, may have reached its handler. *)
type progress =
  | Nothing_left
  | Maybe_handled
  | Refused of { refusal : refusal; maybe_handled_before : bool }

type scope = {
  host : string;
  port : int;
  expected : Masc.Tui_decode.server_identity;
  progress : progress Atomic.t;
}

let scope_key : scope option Eio.Fiber.key = Eio.Fiber.create_key ()

let current () =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> None
  | Eio_fiber -> Option.join (Eio.Fiber.get scope_key)

let same_paths (a : Masc.Tui_decode.server_identity) (b : Masc.Tui_decode.server_identity) =
  Canonical_path.equal a.sid_base_path b.sid_base_path
  && Canonical_path.equal a.sid_masc_root b.sid_masc_root

let expects identity =
  match current () with
  | None -> false
  | Some scope -> same_paths scope.expected identity

let without load =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> load ()
  | Eio_fiber -> Eio.Fiber.with_binding scope_key None load

let rec record scope step =
  let before = Atomic.get scope.progress in
  let after =
    match before, step with
    | Refused _, (`Refused _ | `Maybe_handled) -> before
    | Nothing_left, `Refused refusal -> Refused { refusal; maybe_handled_before = false }
    | Maybe_handled, `Refused refusal -> Refused { refusal; maybe_handled_before = true }
    | (Nothing_left | Maybe_handled), `Maybe_handled -> Maybe_handled
  in
  if not (Atomic.compare_and_set scope.progress before after) then record scope step

(* Outside Eio there is no fiber to own a scope: [request] runs unscoped, and
   [expects] stays false, so the guard keeps asking [/health] first. *)
let run ~host ~port ~expected ~on_workspace_refused ~withdrawn request =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> request ()
  | Eio_fiber ->
  let scope = { host; port; expected; progress = Atomic.make Nothing_left } in
  let result = Eio.Fiber.with_binding scope_key (Some scope) request in
  match Atomic.get scope.progress with
  | Nothing_left | Maybe_handled -> result
  | Refused { refusal = Precondition.Invalid_precondition _; maybe_handled_before = _ } -> result
  | Refused
      { refusal = (Precondition.Workspace_mismatch | Precondition.Server_booting) as refusal
      ; maybe_handled_before } ->
    on_workspace_refused refusal;
    if maybe_handled_before then result else withdrawn ()

type prepared = {
  sent_headers : (string * string) list;
  carried : scope option;
}

let headers prepared = prepared.sent_headers

let precondition_header_names =
  [ Precondition.expected_base_path_header; Precondition.expected_masc_root_header ]

let names_precondition headers =
  List.exists (fun (name, _) ->
    List.mem (String.lowercase_ascii name) precondition_header_names) headers

(* The precondition goes only to the server the scope reads. A request to any
   other address, such as a link preview, must not learn local paths. *)
let same_endpoint scope ~url =
  let uri = Uri.of_string url in
  Option.equal String.equal (Uri.host uri) (Some scope.host)
  && Option.equal Int.equal (Uri.port uri) (Some scope.port)

let prepare ~url headers =
  match current () with
  | Some scope when same_endpoint scope ~url && not (names_precondition headers) ->
    { sent_headers =
        headers
        @ [ Precondition.expected_base_path_header,
            Canonical_path.to_string scope.expected.sid_base_path
          ; Precondition.expected_masc_root_header,
            Canonical_path.to_string scope.expected.sid_masc_root ]
    ; carried = Some scope }
  | Some _ | None -> { sent_headers = headers; carried = None }

type answer =
  | Answered of { status : int; body : string }
  | Unanswered

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) | None -> None

(* The refusal is read from the [code] the server's [Server_refusal] body
   carries, never from its sentence. *)
let refusal_of_answer ~status ~body =
  match Yojson.Safe.from_string body with
  | `Assoc fields ->
    (match string_field "code" fields, string_field "error" fields with
     | Some code, Some error -> Precondition.refusal_of_answer ~status ~code ~error
     | Some _, None | None, (Some _ | None) -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
  | exception Yojson.Json_error _ -> None

let observe prepared answer =
  match prepared.carried with
  | None -> ()
  | Some scope ->
    let step =
      match answer with
      | Unanswered -> `Maybe_handled
      | Answered { status; _ } when Masc.Tui_decode.is_success_http_status status ->
        `Maybe_handled
      | Answered { status; body } ->
        (match refusal_of_answer ~status ~body with
         | Some refusal -> `Refused refusal
         | None -> `Maybe_handled)
    in
    record scope step
