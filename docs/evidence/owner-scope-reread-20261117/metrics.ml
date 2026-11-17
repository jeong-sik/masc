let hashes=Atomic.make 0
let parses=Atomic.make 0
let reads=Atomic.make 0
let raw : string Weak.t list ref = ref []
let requests : Yojson.Safe.t Weak.t list ref = ref []
let sample=ref (fun ()->())
let mutex=Mutex.create ()
let bump counter=ignore (Atomic.fetch_and_add counter 1)
let weak value=let w=Weak.create 1 in Weak.set w 0 (Some value);w
let note value=let w=weak value in Mutex.protect mutex (fun ()->raw:=w:: !raw)
let note_request value=let w=weak value in Mutex.protect mutex (fun ()->requests:=w:: !requests)
let reset ()=Atomic.set hashes 0;Atomic.set parses 0;Atomic.set reads 0;raw:=[];requests:=[];sample:=(fun ()->())
