"""Observe a real language server using a standalone, owned OCaml document.
No Dune build, product server restart, or Keeper action is performed.
"""
import argparse,json,os,pathlib,selectors,subprocess,time

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--server",required=True)
    parser.add_argument("--output",type=pathlib.Path,required=True)
    parser.add_argument("--unversioned-client",action="store_true")
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=False)
    workspace=args.output/"workspace";workspace.mkdir()
    path=workspace/"sample.ml";path.write_text("let value =\n")
    uri=path.resolve().as_uri()
    process=subprocess.Popen([args.server],cwd=workspace,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ,"stdout");selector.register(process.stderr,selectors.EVENT_READ,"stderr")
    wire=bytearray();events=[];stderr=[]
    receipt={"scope":"Real ocamllsp protocol on a synthetic standalone file; not installed IDE or Keeper evidence","pid":process.pid,"server":args.server,"passed":False}
    def send(value):
        data=json.dumps(value,separators=(",",":"),ensure_ascii=False).encode()
        process.stdin.write(("Content-Length: %d\r\n\r\n"%len(data)).encode()+data);process.stdin.flush()
        events.append({"direction":"sent","message":value})
    def receive(predicate):
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            while b"\r\n\r\n" in wire:
                header,remaining=bytes(wire).split(b"\r\n\r\n",1)
                lengths=[int(line.split(b":",1)[1]) for line in header.split(b"\r\n") if line.lower().startswith(b"content-length:")]
                if len(lengths)!=1:raise ValueError("invalid LSP framing")
                if len(remaining)<lengths[0]:break
                data=remaining[:lengths[0]];wire[:]=remaining[lengths[0]:]
                value=json.loads(data);events.append({"direction":"received","message":value})
                if predicate(value):return value
                if "method" in value and "id" in value:
                    send({"jsonrpc":"2.0","id":value["id"],"error":{"code":-32601,"message":"Fixture client does not implement this method"}})
            ready=selector.select(min(1,max(0,deadline-time.monotonic())))
            for key,_ in ready:
                data=os.read(key.fileobj.fileno(),65536)
                if not data:
                    selector.unregister(key.fileobj)
                    if key.data=="stdout":raise RuntimeError("language server output closed")
                elif key.data=="stdout":wire.extend(data)
                else:stderr.append(data.decode("utf-8",errors="replace"))
        raise TimeoutError("30-second observation ended without the expected protocol event")
    try:
        send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":os.getpid(),"rootUri":workspace.resolve().as_uri(),"capabilities":{} if args.unversioned_client else {"textDocument":{"publishDiagnostics":{"versionSupport":True}}},"workspaceFolders":[{"uri":workspace.resolve().as_uri(),"name":"probe"}]}})
        initialized=receive(lambda m:m.get("id")==1);assert "result" in initialized,initialized
        receipt["capabilities"]=initialized["result"]["capabilities"]
        send({"jsonrpc":"2.0","method":"initialized","params":{}})
        send({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"ocaml","version":1,"text":path.read_text()}}})
        bad=receive(lambda m:m.get("method")=="textDocument/publishDiagnostics" and m.get("params",{}).get("uri")==uri and any(d.get("severity")==1 for d in m["params"].get("diagnostics",[])))
        receipt["invalid_document_diagnostics"]=bad["params"]
        path.write_text("let value = 1\n")
        send({"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":uri,"version":2},"contentChanges":[{"text":path.read_text()}]}})
        good=receive(lambda m:m.get("method")=="textDocument/publishDiagnostics" and m.get("params",{}).get("uri")==uri and not any(d.get("severity")==1 for d in m["params"].get("diagnostics",[])))
        receipt["valid_document_diagnostics"]=good["params"]
        send({"jsonrpc":"2.0","id":2,"method":"textDocument/diagnostic","params":{"textDocument":{"uri":uri}}})
        receipt["pull_diagnostics_response"]=receive(lambda m:m.get("id")==2)
        send({"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":uri}}})
        send({"jsonrpc":"2.0","id":3,"method":"shutdown"})
        receive(lambda m:m.get("id")==3)
        send({"jsonrpc":"2.0","method":"exit"})
        process.wait(timeout=5)
        receipt["passed"]=True
    except Exception as error:
        receipt["error"]=type(error).__name__+": "+str(error)
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
        receipt["exit_code"]=process.returncode
        (args.output/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
        (args.output/"protocol.json").write_text(json.dumps(events,indent=2)+"\n")
        (args.output/"stderr.txt").write_text("".join(stderr))
        selector.close()
    print(json.dumps({"output":str(args.output),"passed":receipt["passed"],"invalid_version":receipt["invalid_document_diagnostics"].get("version"),"valid_version":receipt["valid_document_diagnostics"].get("version")}))

if __name__=="__main__":main()
