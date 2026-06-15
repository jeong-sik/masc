type t =
  { buf : Buffer.t
  ; mutable live_emitted : bool
  }

let create () = { buf = Buffer.create 256; live_emitted = false }

let on_delta t ~redact text =
  Buffer.add_string t.buf text;
  t.live_emitted <- true;
  redact text

let streamed_text t = Buffer.contents t.buf
let suppress_terminal_resend t = t.live_emitted
