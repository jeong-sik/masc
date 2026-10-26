module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module O = Endpoint_job_output
module G = Endpoint_process_gate
let ( let* ) = Result.bind
type error =
  | Registry_error of R.error
  | Output_error of { stream : P.stream; cause : O.error }
  | Codec_error of P.codec_error
  | Invalid_receipt | Storage_unavailable
  | Sync_failed of Fs_compat.owned_regular_file_read_error
let error_to_string = function
  | Registry_error e -> R.error_to_string e
  | Output_error {stream;cause} ->
    (match stream with P.Stdout -> "stdout: " | Stderr -> "stderr: ") ^ O.error_to_string cause
  | Codec_error e -> P.error_to_string e
  | Invalid_receipt -> "original terminal receipt invalid"
  | Storage_unavailable -> "original terminal receipt unavailable"
  | Sync_failed e -> Fs_compat.owned_regular_file_read_error_to_string e
type input_delivery = Accepted of int64 | Incomplete of { confirmed_prefix : int64 }
type preparation = Pending | Ready | Rejected of { diagnostic : string }
type gate = { preparation : preparation; decision : G.decision; control : G.control }
type seal = { byte_length : int64; sha256 : P.Sha256.t }
type frozen = {
  original : P.original; revision : int64; cancel_requested : bool;
  physical_status : P.exit_status; launch_id : P.Id.t; input : input_delivery;
  gate : gate; stdout : seal; stderr : seal;
}
type t = {
  source : R.record; directory : Eio.Fs.dir_ty Eio.Path.t;
  receipt : Fs_compat.owned_reader; receipt_stat : Eio.File.Stat.t;
  stdout : O.t; stderr : O.t; frozen : frozen; digest : P.Sha256.t;
}
let leaf="terminal-result.json"
let sha256 t=t.digest
let input_delivery t=t.frozen.input
let gate t=t.frozen.gate
let cpu f=Domain_pool_ref.submit_cpu_or_inline f
let io f=try Ok (f ()) with
  | Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _ | End_of_file -> Error Storage_unavailable
let invalid ()=Error Invalid_receipt
let fields required = function
  | `Assoc values ->
    if List.length values=List.length required
        && List.for_all (fun name -> List.length (List.filter (fun (key,_) -> key=name) values)=1) required
      then Ok values else invalid ()
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid ()
let text = function
  | `String value -> Ok value
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> invalid ()
let count value =
  let* value=text value in
  match Int64.of_string_opt value with
  | Some n when n>=0L && Int64.to_string n=value -> Ok n
  | None | Some _ -> invalid ()
let object_state value =
  match value with
  | `Assoc values -> (match List.assoc_opt "state" values with Some value -> text value | None -> invalid ())
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid ()
let read_input value =
  let* state=object_state value in
  match state with
  | "written" -> let* values=fields ["state";"byte_length"] value in
    let* bytes=count (List.assoc "byte_length" values) in Ok (Accepted bytes)
  | "write_failed" -> let* values=fields ["state";"confirmed_prefix"] value in
    let* confirmed_prefix=count (List.assoc "confirmed_prefix" values) in Ok (Incomplete {confirmed_prefix})
  | _ -> invalid ()
let read_preparation value =
  let* state=object_state value in
  match state with
  | "pending" -> let* _=fields ["state"] value in Ok Pending
  | "ready" -> let* _=fields ["state"] value in Ok Ready
  | "rejected" ->
    let* values=fields ["state";"diagnostic_b64"] value in
    let* encoded=text (List.assoc "diagnostic_b64" values) in
    (match Base64.decode encoded with
     | Ok diagnostic when Base64.encode_string diagnostic=encoded -> Ok (Rejected {diagnostic})
     | Ok _ | Error _ -> invalid ())
  | _ -> invalid ()
let read_gate value =
  let* values=fields ["preparation";"decision";"control"] value in
  let* preparation=read_preparation (List.assoc "preparation" values) in
  let* decision=text (List.assoc "decision" values) in
  let* decision=match decision with
    | "undecided" -> Ok G.Undecided | "activate_requested" -> Ok G.Activate_requested
    | "abort_requested" -> Ok G.Abort_requested | _ -> invalid () in
  let* control=text (List.assoc "control" values) in
  let* control=match control with "open" -> Ok G.Open | "ended" -> Ok G.Ended | _ -> invalid () in
  Ok {preparation;decision;control}
let decode_payload json =
  let* values=fields ["status";"launch_id";"stdin";"gate"] json in
  let* status=P.response_of_json (List.assoc "status" values) |> Result.map_error (fun e -> Codec_error e) in
  let* launch_id=text (List.assoc "launch_id" values) in
  let* launch_id=P.Id.of_string launch_id |> Result.map_error (fun _ -> Invalid_receipt) in
  let* input=read_input (List.assoc "stdin" values) in
  let* gate=read_gate (List.assoc "gate" values) in
  match status with
  | P.Status {original;revision;cancel_requested;phase;result;stdout;stderr} ->
    let* physical_status=match phase with
      | P.Termination_observed physical -> Ok physical
      | Queued | Starting | Running | Finished _ | Not_started _ -> invalid () in
    let* ()=match result with P.Result_pending -> Ok () | Result_ready _ -> invalid () in
    let sealed = function
      | P.Sealed {byte_length;sha256} -> Ok ({byte_length;sha256} : seal)
      | Growing _ -> invalid () in
    let* stdout=sealed stdout in
    let* stderr=sealed stderr in
    Ok {original;revision;cancel_requested;physical_status;launch_id;input;gate;
      stdout;stderr}
  | P.Admitted _ | Output _ | Released _ | Refused _ | Held _ -> invalid ()
let payload_digest payload =
  let content="masc_endpoint_terminal_result_v1\000" ^ Yojson.Safe.to_string payload in
  Digestif.SHA256.(to_hex (digest_string content))
let decode content =
  let json=try Ok (Yojson.Safe.from_string content) with Yojson.Json_error _ -> invalid () in
  let* json=json in
  let* values=fields ["version";"payload";"payload_sha256"] json in
  let* ()=if List.assoc "version" values=`Int 1 then Ok () else invalid () in
  let payload=List.assoc "payload" values in
  let* expected=text (List.assoc "payload_sha256" values) in
  let* expected=P.Sha256.of_string expected |> Result.map_error (fun _ -> Invalid_receipt) in
  let* ()=if payload_digest payload=P.Sha256.to_string expected then Ok () else invalid () in
  decode_payload payload
let encode ~status ~launch_id ~input ~(gate : gate) =
  let* status=P.response_to_json status |> Result.map_error (fun e -> Codec_error e) in
  let input=match input with
    | Accepted bytes -> `Assoc ["state",`String "written";"byte_length",`String (Int64.to_string bytes)]
    | Incomplete {confirmed_prefix} -> `Assoc ["state",`String "write_failed";"confirmed_prefix",`String (Int64.to_string confirmed_prefix)] in
  let preparation=match gate.preparation with
    | Pending -> `Assoc ["state",`String "pending"] | Ready -> `Assoc ["state",`String "ready"]
    | Rejected {diagnostic} -> `Assoc ["state",`String "rejected";"diagnostic_b64",`String (Base64.encode_string diagnostic)] in
  let decision=match gate.decision with
    | G.Undecided -> "undecided" | Activate_requested -> "activate_requested" | Abort_requested -> "abort_requested" in
  let control=match gate.control with G.Open -> "open" | Ended -> "ended" in
  let payload=`Assoc ["status",status;"launch_id",`String (P.Id.to_string launch_id);"stdin",input;
    "gate",`Assoc ["preparation",preparation;"decision",`String decision;"control",`String control]] in
  let* _=decode_payload payload in
  Ok (Yojson.Safe.to_string (`Assoc ["version",`Int 1;"payload",payload;"payload_sha256",`String (payload_digest payload)]))
let source frozen record =
  let original=P.original ~binding:(R.binding record) ~admission_id:(R.admission_id record) in
  let revision=R.revision record in
  let cancelled=R.cancellation_state record=R.Cancellation_requested in
  (* The original known launch has only its one monotone cancellation step;
     older arbitrary revisions are not historical termination evidence. *)
  let progress=if frozen.revision=revision then frozen.cancel_requested=cancelled
    else frozen.revision<revision && not frozen.cancel_requested && cancelled
      && Int64.succ frozen.revision=revision in
  let* ()=if frozen.original=original && progress
    then Ok () else invalid () in
  let* ()=match R.launch_state record with
    | R.Requested actual when actual=frozen.launch_id -> Ok ()
    | R.Not_requested | Requested _ -> invalid () in
  let length=Int64.of_int (String.length (R.specification record).stdin) in
  match frozen.input with
  | Accepted n -> if n=length then Ok () else invalid ()
  | Incomplete {confirmed_prefix} -> if confirmed_prefix<=length then Ok () else invalid ()
let stable_stat (before : Eio.File.Stat.t) (after : Eio.File.Stat.t) = {before with atime=after.atime}=after
let private_receipt (stat : Eio.File.Stat.t) =
  stat.kind=`Regular_file && stat.uid=Int64.of_int (Unix.geteuid ())
  && stat.nlink=1L && stat.perm land 0o7777=0o400
let receipt_valid directory reader expected =
  let* held=io (fun () -> Fs_compat.owned_reader_stat reader) in
  let* canonical=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(directory / leaf)) in
  if private_receipt held && private_receipt canonical
      && stable_stat expected held && stable_stat expected canonical then Ok () else invalid ()
let output_error stream value=Result.map_error (fun cause -> Output_error {stream;cause}) value
let validate_seal stream (expected : seal) output =
  let* actual=O.revalidate_sealed output |> output_error stream in
  if actual.byte_length=expected.byte_length && actual.sha256=expected.sha256 then Ok () else invalid ()
let validate t =
  let* record=R.refresh t.source |> Result.map_error (fun e -> Registry_error e) in
  let* ()=source t.frozen record in
  let* ()=validate_seal P.Stdout t.frozen.stdout t.stdout in
  let* ()=validate_seal P.Stderr t.frozen.stderr t.stderr in
  let* ()=receipt_valid t.directory t.receipt t.receipt_stat in
  Ok record
let inspect t =
  let* record=validate t in
  let extent (seal : seal)=P.Sealed {byte_length=seal.byte_length;sha256=seal.sha256} in
  Ok (P.Status {original=t.frozen.original;revision=R.revision record;
    phase=P.Termination_observed t.frozen.physical_status;
    cancel_requested=R.cancellation_state record=R.Cancellation_requested;
    result=P.Result_ready t.digest;stdout=extent t.frozen.stdout;stderr=extent t.frozen.stderr})
let read_output t ~stream ~offset ~max_bytes =
  let* _=validate t in
  let output=match stream with P.Stdout -> t.stdout | Stderr -> t.stderr in
  let* chunk=O.read output ~offset ~max_bytes |> output_error stream in
  let* _=validate t in Ok chunk
let load_with_hook ~after_receipt_read ~before_ready ~sw ~storage ~expected_sha256 =
  Eio.Switch.check sw;
  let* record=R.refresh (R.storage_record storage) |> Result.map_error (fun e -> Registry_error e) in
  let directory=R.storage_path storage in
  let* before=io (fun () -> Eio.Path.stat ~follow:false Eio.Path.(directory / leaf)) in
  let* ()=if private_receipt before then Ok () else invalid () in
  let* reader=io (fun () -> Fs_compat.open_owned_reader ~sw ~parent:directory ~leaf) in
  let* reader=reader |> Result.map_error (fun _ -> Invalid_receipt) in
  let* ()=receipt_valid directory reader before in
  let length=Optint.Int63.to_int64 before.size in
  let* ()=if length>=0L && length<=Int64.of_int Sys.max_string_length then Ok () else invalid () in
  let buffer=Buffer.create (min 65536 (Int64.to_int length)) in
  let rec read position =
    if position=length then Ok (Buffer.contents buffer) else
    let count=Int64.min 65536L (Int64.sub length position) |> Int64.to_int in
    let* chunk=io (fun () -> Fs_compat.owned_reader_pread reader ~offset:position ~length:count) in
    let n=String.length chunk in
    if n=0 then Error Storage_unavailable else (
      Buffer.add_string buffer chunk;read (Int64.add position (Int64.of_int n))) in
  let* content=read 0L in
  let* ()=receipt_valid directory reader before in
  after_receipt_read ();
  let* frozen=cpu (fun () -> decode content) in
  let* ()=source frozen record in
  let* digest=cpu (fun () -> P.Sha256.of_string Digestif.SHA256.(to_hex (digest_string content)))
    |> Result.map_error (fun _ -> Invalid_receipt) in
  let* ()=match expected_sha256 with
    | None -> Ok () | Some expected -> if expected=digest then Ok () else invalid () in
  let* stdout=O.reopen ~sw ~storage ~stream:P.Stdout |> output_error P.Stdout in
  let* stderr=O.reopen ~sw ~storage ~stream:P.Stderr |> output_error P.Stderr in
  let t={source=record;directory;receipt=reader;receipt_stat=before;stdout;stderr;frozen;digest} in
  let* _=validate t in
  let* synced=io (fun () -> Fs_compat.sync_owned_reader ~parent:directory ~leaf reader) in
  let* ()=synced |> Result.map_error (fun e -> Sync_failed e) in
  before_ready ();
  let* _=validate t in
  Eio.Switch.check sw;
  Ok t

let load ~sw ~storage ~expected_sha256 =
  load_with_hook ~after_receipt_read:(fun () -> ()) ~before_ready:(fun () -> ()) ~sw ~storage ~expected_sha256
module For_testing = struct
  let load=load_with_hook
end
