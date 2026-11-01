module Event = Execution_event

type header =
  { batch_id : string
  ; expected_next_seq : int
  ; count : int
  ; events_sha256 : string
  }

type footer =
  { batch_id : string
  ; first_seq : int
  ; last_seq : int
  ; count : int
  ; events_sha256 : string
  }

type failure =
  { offset : int64
  ; detail : string
  }

type in_progress =
  { header : header
  ; correlation_id : Event.Correlation_id.t
  ; accepted_count : int
  }

type validated = Validated of int

let start ~offset ~committed_seq ~correlation_id (header : header) =
  if header.expected_next_seq <= 0
  then Error { offset; detail = "batch sequence must be positive" }
  else if header.count <= 0
  then Error { offset; detail = "batch count must be positive" }
  else if header.expected_next_seq <> committed_seq + 1
  then
    Error
      { offset
      ; detail =
          Printf.sprintf
            "batch starts at sequence %d after committed sequence %d"
            header.expected_next_seq
            committed_seq
      }
  else Ok { header; correlation_id; accepted_count = 0 }

let remaining (progress : in_progress) = progress.header.count - progress.accepted_count

let next_seq (progress : in_progress) =
  progress.header.expected_next_seq + progress.accepted_count

let accept_event (progress : in_progress) ~offset event =
  if remaining progress <= 0
  then Error { offset; detail = "batch accepted event count exceeded header count" }
  else
    let expected_seq = next_seq progress in
    if Event.seq event <> expected_seq
    then
      Error
        { offset
        ; detail =
            Printf.sprintf
              "event sequence %d does not match expected sequence %d"
              (Event.seq event)
              expected_seq
        }
    else if
      not (Event.Correlation_id.equal (Event.correlation_id event) progress.correlation_id)
    then Error { offset; detail = "event correlation mismatch" }
    else Ok { progress with accepted_count = progress.accepted_count + 1 }

let finish (progress : in_progress) ~offset ~digest (footer : footer) =
  let header = progress.header in
  let expected_last = header.expected_next_seq + header.count - 1 in
  if remaining progress <> 0
  then
    Error
      { offset
      ; detail =
          Printf.sprintf
            "batch accepted %d of %d declared events"
            progress.accepted_count
            header.count
      }
  else if not (String.equal footer.batch_id header.batch_id)
  then Error { offset; detail = "batch commit identity mismatch" }
  else if
    footer.first_seq <> header.expected_next_seq
    || footer.last_seq <> expected_last
    || footer.count <> header.count
  then Error { offset; detail = "batch commit range mismatch" }
  else if
    (not (String.equal header.events_sha256 digest))
    || not (String.equal footer.events_sha256 digest)
  then Error { offset; detail = "batch event digest mismatch" }
  else Ok (Validated expected_last)

let last_seq (Validated seq) = seq
