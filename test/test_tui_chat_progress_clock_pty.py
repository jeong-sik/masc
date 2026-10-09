"""A resumed two-day request obeys Ctrl-F for progress timers as well as clocks."""
import os
import re
import sys
import json
import threading
import time
import urllib.parse
import tui_keyboard_harness as h
import tui_keyboard_observer as observer


def enter(process, fd, output, marker):
    h.wait_for_output(process, fd, output, b'MASC Dashboard', start=0, timeout=5)
    h.send_and_wait(process, fd, output, b'3', b'MASC Keepers')
    h.select_keeper_row(process, fd, output, b'alpha')
    h.palette_go(process, fd, output, b'keeper alpha', marker)
    h.drain_until_quiet(process, fd, output)


def leave(process, fd, output):
    h.send_and_wait(process, fd, output, b'\x11', b'MASC Keepers')
    os.write(fd, b'q')


def run(executable):
    operation='quiet-checkpoint';started=time.time()-2*24*60*60
    resumed=threading.Event();failed=threading.Event();finished=threading.Event();requested=threading.Event()
    connected=threading.Event()
    events=[
      {'type':'run_started','run_id':'quiet-run','thread_id':'keeper:alpha'},
      {'type':'text_delta','delta':'CHECKPOINT_OUTPUT'},
      {'type':'reply_details','reply':'','turn_outcome':'continuation_checkpoint','turn_ref':'trace-quiet#1'},
      {'type':'run_finished','run_id':'quiet-run'},
      {'type':'run_started','run_id':'resumed-run','thread_id':'keeper:alpha'},
      {'type':'text_delta','delta':'RESUMED_OUTPUT'},
      {'type':'event_error','message':'VISIBLE_FAILURE'},
    ]
    def journal(path):
        q=urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
        assert q['operation_id']==[operation], q
        since=int(q.get('since_seq',['-1'])[0]);last=6 if failed.is_set() else 5 if resumed.is_set() else 3
        requested.set()
        return 200,{'schema':'masc.keeper_chat_events.v2','operation_id':operation,
          'events':[{'v':1,'seq':i,'ts':started+i if i<4 else time.time()-10,'event':e}
                    for i,e in enumerate(events) if since<i<=last],
          'has_more':False,'next_since_seq':last,'next_since_offset':100*(last+1)}
    def frame(seq):
        return b'data: '+json.dumps({'type':'keeper_chat_operation_event','name':'alpha',
          'operation_id':operation,'seq':seq,'ts_unix':time.time(),
          'ag_ui_event':{'type':'CUSTOM','name':'fixture-journal-grew'}}).encode()+b'\n\n'
    def chunks():
        connected.set();yield b': observer connected\n\n'
        if resumed.wait(20): yield frame(5)
        if failed.wait(20): yield frame(6)
        finished.wait(20)
    fixtures=h.keeper_runtime_http_fixtures();fixtures.update(observer.observer_http_fixtures())
    fixtures['/api/v1/keepers/alpha/chat/history']=(200,[{'id':'quiet-question','role':'user',
      'content':'OPEN_REQUEST','ts':started,'speaker_authority':'owner',
      'transcript_slot':{'kind':'accepted_user'},'delivery_key':{'kind':'operation','operation_id':operation}}])
    # Live progress is drawn only for an operation the server reports Running,
    # and the client reads that record before each journal read.
    def operation_record(_path):
        record:dict[str,object]={'schema':'masc.keeper_chat_operation.v1','operation_id':operation}
        if failed.is_set():
            record.update(state='Failed',completed_at=time.time(),
                          failure_kind='Turn_exception',failure_detail='VISIBLE_FAILURE')
        else:
            record.update(state='Running',started_at=started)
        return 200,record
    fixtures['/api/v1/keepers/alpha/chat/operations/'+operation]=h.PathHttpResponse(operation_record)
    fixtures['/api/v1/keepers/alpha/chat/events']=h.PathHttpResponse(journal)
    fixtures['/api/v1/keepers/alpha/memory-journal?limit=20']=(200,{'entries':[]})
    fixtures['/api/v1/keepers/turns']=(200,{'schema':'masc.keeper_turns.v1',
      'keepers':[{'keeper_name':'alpha','status':'ok','chat_control_token':None,'turn':None}]})
    fixtures['/mcp?sse_kind=observer']=h.StreamingHttpResponse(chunks)
    def interact(process,fd,_slave,output,_base):
        try:
            enter(process,fd,output,b'OPEN_REQUEST')
            assert h.wait_for_fixture_event(process,fd,output,requested,timeout=5)
            assert h.wait_for_fixture_event(process,fd,output,connected,timeout=5)
            h.wait_for_output(process,fd,output,b'CHECKPOINT_OUTPUT',start=0,timeout=5)
            h.drain_until_quiet(process,fd,output)
            quiet=h.screen_text(bytes(output))
            assert b'CHECKPOINT_OUTPUT' in quiet and b'OPEN_REQUEST' in quiet
            assert b'WAITING TO START' not in quiet and b'IN PROGRESS' not in quiet, quiet
            assert b'request is still open' not in quiet, quiet
            assert not re.search(rb'\d\d:\d\d',quiet), quiet
            at=len(output);resumed.set()
            h.wait_for_output(process,fd,output,b'RESUMED_OUTPUT',start=at,timeout=5)
            h.drain_until_quiet(process,fd,output)
            running=h.screen_text(bytes(output))
            assert b'IN PROGRESS' in running and b'RESUMED_OUTPUT' in running, running
            assert b'2d00h' not in running and b'nothing back for' not in running, running
            h.send_and_wait(process,fd,output,b'\x06',b'metadata:inline')
            timed=h.screen_text(bytes(output))
            assert b'2d00h' in timed and b'nothing back for' in timed, timed
            h.send_and_wait(process,fd,output,b'\x06',b'metadata:full')
            h.send_and_wait(process,fd,output,b'\x06',b'RESUMED_OUTPUT')
            quiet_again=h.screen_text(bytes(output))
            assert b'2d00h' not in quiet_again and b'nothing back for' not in quiet_again, quiet_again
            at=len(output);failed.set()
            h.wait_for_output(process,fd,output,b'VISIBLE_FAILURE',start=at,timeout=5)
            h.drain_until_quiet(process,fd,output)
            error=h.screen_text(bytes(output))
            assert b'VISIBLE_FAILURE' in error, error
            leave(process,fd,output)
        finally:
            resumed.set();failed.set();finished.set()
    h.run_terminal_scenario(executable,description='Idle checkpoint resumes and shows errors',interact=interact,
      http_fixtures=fixtures,refresh=3600.,terminal_rows=36,terminal_cols=120)
    print('PASS: 2-day checkpoint is quiet; resume restores progress; error stays visible',flush=True)

if __name__ == '__main__':
    run(os.path.abspath(sys.argv[1]))
