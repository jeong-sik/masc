import hashlib,json,os,pathlib,socket,subprocess,sys,tempfile,time,urllib.request,urllib.error,urllib.parse
exe=pathlib.Path(sys.argv[1]).resolve();out=pathlib.Path(sys.argv[2]).resolve();out.mkdir(parents=True,exist_ok=True)
env={k:v for k,v in os.environ.items() if not k.startswith('MASC_')}
with tempfile.TemporaryDirectory(prefix='masc-play-candidate-') as base:
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    env['MASC_BASE_PATH']=base;env['MASC_HTTP_BASE_URL']=f'http://127.0.0.1:{port}'
    login=subprocess.run([str(exe),'login','--base-path',base,'--port',str(port),'--agent','play-proof','--client-env','MASC_TOKEN','--json'],env=env,capture_output=True,check=True)
    tokens=list(pathlib.Path(base,'.masc','auth').glob('*.token'));assert len(tokens)==1
    admin=tokens[0].read_text().strip();origin=f'http://127.0.0.1:{port}'
    def req(path,method='GET',data=None,token=admin,authority=None):
        headers={'Content-Type':'application/json'}
        if token:headers['Authorization']='Bearer '+token
        if authority:headers['Host']=authority
        request=urllib.request.Request(origin+path,data=None if data is None else json.dumps(data).encode(),method=method,headers=headers)
        try:
            with urllib.request.urlopen(request,timeout=10) as r:return r.status,r.read()
        except urllib.error.HTTPError as e:return e.code,e.read()
    with (out/'candidate-server-startup.log').open('w') as logfile:
        p=subprocess.Popen([str(exe),'start','--base-path',base,'--port',str(port),'--host','127.0.0.1'],env=env,stdout=logfile,stderr=subprocess.STDOUT)
        try:
            until=time.monotonic()+60
            while True:
                if p.poll() is not None:raise RuntimeError('candidate exited '+str(p.returncode))
                try:
                    status,body=req('/health/ready',token=None)
                    if status==200:break
                except (OSError,urllib.error.URLError):pass
                if time.monotonic()>until:raise RuntimeError('candidate not ready')
                time.sleep(.25)
            assert req('/api/v1/play/invites',token=None)[0]==401
            status,body=req('/api/v1/play/invites','POST',{'name':'guestproof','hours':1});assert status==201,(status,body)
            invite=json.loads(body);player=urllib.parse.urlsplit(invite['link']).fragment
            assert player and urllib.parse.urlsplit(invite['link']).netloc==urllib.parse.urlsplit(env['MASC_HTTP_BASE_URL']).netloc
            status,body=req('/api/v1/play/invites');assert status==200
            assert any(row['name']=='guestproof' for row in json.loads(body)['invites'])
            status,body=req('/play',token=None);assert status==200 and b'masc.play.invite' in body
            seat_status,seat_body=req('/api/v1/play/seat',token=player)
            assert seat_status==200
            assert json.loads(seat_body)['controller_recoverable'] is False
            room='/api/v1/play/room'
            assert req(room,token=None)[0]==401
            def room_post(actor,body,status=200):
                actual,raw=req(room,'POST',body,token=actor)
                assert actual==status,(actual,raw)
                return json.loads(raw)
            request={'action':'say','client_id':'browser1','machine':'dos','message_id':'one','text':'함께 보기'}
            first=room_post(player,request)
            assert first['viewer']=='guestproof'
            assert first['messages'][0]['who']=='guestproof'
            assert len(room_post(player,request)['messages'])==1
            room_post(player,{**request,'text':'different'},409)
            room_post(player,{**request,'who':'forged'},400)
            reply={'action':'say','client_id':'tui1','machine':'msx','message_id':'reply','text':'TUI reply'}
            assert room_post(admin,reply)['viewer']=='play-proof'
            status,raw=req(room,token=player);assert status==200
            messages=json.loads(raw)['messages'];assert [m['text'] for m in messages]==['함께 보기','TUI reply']
            assert req(room+'?before=bogus',token=player)[0]==400
            assert len(json.loads(req(room+'?before='+str(messages[1]['id']),token=player)[1])['messages'])==1
            room_post(player,{'action':'join','client_id':'browser2','machine':'msx'})
            left=room_post(player,{'action':'leave','client_id':'browser1','machine':'dos'})
            assert 'guestproof' in [m['name'] for m in left['members']]
            left=room_post(player,{'action':'leave','client_id':'browser2','machine':'msx'})
            assert 'guestproof' not in [m['name'] for m in left['members']]
            assert b'masc_play_room' in req('/play/agent.md',token=None)[1]
            assert req('/api/v1/play/invites',token=player)[0]==403
            assert req('/api/v1/play/invites/guestproof','DELETE',token=player)[0]==403
            assert any(row['name']=='guestproof' for row in json.loads(req('/api/v1/play/invites')[1])['invites'])
            status,body=req('/api/v1/play/invites/guestproof','DELETE');assert status==200 and json.loads(body)['revoked']
            assert req('/api/v1/play/seat',token=player)[0]==401
            assert req(room,token=player)[0]==401
            assert req(room,'POST',request,token=player)[0]==401
            assert json.loads(req('/api/v1/play/invites')[1])['invites']==[]
            public_host=urllib.parse.urlsplit(env['MASC_HTTP_BASE_URL']).netloc
            assert req('/play',token=None,authority=public_host)[0]==200
            assert req('/play',token=None,authority='unconfigured.example.test')[0]==400
            receipt={'pass':True,'binary_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'checks':['ready','anonymous-denied','issue','inventory','candidate-page','player-view','player-admin-denied','revoke','revoked-view-denied','empty-inventory','configured-host-accepted','unconfigured-host-rejected','room-anonymous-denied','room-authenticated-speaker','room-idempotency','room-conflict','room-forgery-denied','room-shared-msx-dos-history','room-pagination','room-multiple-clients','room-revocation','room-agent-guide'],'isolated_workspace':True,'shared_server_changed':False}
            (out/'candidate-server-receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt))
        finally:
            p.terminate()
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:p.kill();p.wait()
