(* RFC-0070 Phase 3b-iv.2.5 — pure parser for docker ps JSON output.
   See .mli for the public surface and the silent-drop trade-off
   rationale. Extracted unchanged from docker_client_real.ml (Phase
   3b-iv.2.4 / #14871). *)

let parse_labels (s : string) : (string * string) list =
  if String.equal s ""
  then []
  else (
    let parts = String.split_on_char ',' s in
    List.filter_map
      (fun part ->
         match String.index_opt part '=' with
         | None -> None
         | Some i ->
           let k = String.sub part 0 i in
           let v = String.sub part (i + 1) (String.length part - i - 1) in
           Some (k, v))
      parts)
;;

(* Required-only subset of docker's ps JSON line. [@@deriving
   yojson { strict = false }] tolerates unknown fields like
   [CreatedAt], [Status], [Ports] without failure. *)
type raw_ps_record =
  { id : string [@key "ID"]
  ; names : string [@key "Names"]
  ; state : string [@key "State"]
  ; labels : string [@key "Labels"]
  }
[@@deriving yojson { strict = false }]

let parse_line (line : string) : Docker_response.ps_record option =
  let trimmed = String.trim line in
  if String.equal trimmed ""
  then None
  else (
    match Yojson.Safe.from_string trimmed with
    | exception Yojson.Json_error _ -> None
    | json ->
      (match raw_ps_record_of_yojson json with
       | Error _ -> None
       | Ok raw ->
         (match Docker_response.parse_state raw.state with
          | Error _ -> None
          | Ok status ->
            Some
              Docker_response.
                { id = raw.id
                ; name = Keeper_container_name.of_external_string raw.names
                ; status
                ; labels = parse_labels raw.labels
                })))
;;

let parse_output (stdout : string) : Docker_response.ps_record list =
  String.split_on_char '\n' stdout |> List.filter_map parse_line
;;
