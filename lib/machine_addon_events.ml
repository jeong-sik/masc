type batch = { author : string; relay : author:string -> string -> unit; ready : bool Atomic.t }
type notice = { batch : batch; content : string }
let pending : notice Queue.t = Queue.create ()
let lock = Mutex.create ()
let posting = Eio.Mutex.create ()
let create ~author ~relay = {author;relay;ready=Atomic.make false}
let ready batch = Atomic.set batch.ready true
let record batch (result : Mcp_protocol.Mcp_types.tool_result) =
  let contents = match result._meta with
    | Some (`Assoc fields) ->
        (match List.assoc_opt "io.github.jeong-sik/masc.machine.events" fields with
         | Some (`List events) -> List.filter_map (function
             | `Assoc fields when List.sort String.compare (List.map fst fields) = ["author";"content"] ->
                 (match List.assoc "content" fields with
                  | `String content -> Some content
                  | _ -> Log.Misc.warn "Machine worker returned an invalid event body"; None)
             | _ -> Log.Misc.warn "Machine worker returned an invalid event envelope"; None) events
         | None -> []
         | Some _ -> Log.Misc.warn "Machine worker returned an invalid event list"; [])
    | None | Some _ -> [] in
  Mutex.protect lock (fun () -> List.iter (fun content -> Queue.push {batch;content} pending) contents)
let drain () =
  Eio.Mutex.use_ro posting (fun () ->
    let rec loop () =
      let next = Mutex.protect lock (fun () ->
        match Queue.peek_opt pending with
        | Some notice when Atomic.get notice.batch.ready -> Queue.take_opt pending
        | Some _ | None -> None) in
      match next with
      | None -> ()
      | Some {batch;content} -> batch.relay ~author:batch.author content; loop () in
    loop ())
