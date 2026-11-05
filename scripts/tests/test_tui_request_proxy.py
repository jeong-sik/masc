"""Exercise the TUI request relay against a fake server.

The fake is not MASC. These tests show that the relay frames HTTP/1.1, reads
both sides of a connection at once, names server-sent events, counts the
bytes each side took and forwards the Host the server admits.
"""
import asyncio
import contextlib
import http.client
import importlib
from pathlib import Path
import socket
import sys
import time
import unittest
from unittest import mock

TESTS = Path(__file__).resolve().parent
PERF = TESTS.parent / 'harness' / 'perf'
sys.path[:0] = [str(PERF), str(TESTS)]
http1 = importlib.import_module('tui_request_http')
events = importlib.import_module('tui_request_events')
record = importlib.import_module('tui_request_log')
proxy = importlib.import_module('tui_request_proxy')
fakes = importlib.import_module('tui_request_fakes')

LOOPBACK = fakes.LOOPBACK
SETTLE_TIMEOUT_S = 5.0
Ending = record.Ending
of = fakes.of


class RelayTest(unittest.TestCase):
    def setUp(self):
        self.upstream = fakes.Upstream()
        self.addCleanup(self.upstream.close)
        self.log = record.Log()
        listener = proxy.listen_socket()
        self.addCleanup(listener.close)
        self.port = proxy.bound_port(listener)
        self.enterContext(proxy.serve(listener, self.upstream.port, self.log))

    def connect(self):
        return socket.create_connection((LOOPBACK, self.port), timeout=SETTLE_TIMEOUT_S)

    def forwarded(self, raw):
        return http1.with_authority(raw, f'{LOOPBACK}:{self.upstream.port}'.encode())

    def exchange(self, raw):
        """Send `raw` on a new connection and read until the relay closes it."""
        with self.connect() as client:
            client.sendall(raw)
            return fakes.read_all(client)

    def logged(self, done):
        """The log once `done` holds for its entries."""
        deadline = time.monotonic() + SETTLE_TIMEOUT_S
        while not done(entries := self.log.entries()):
            if time.monotonic() > deadline:
                self.fail(f'relay log did not settle: {entries}')
            time.sleep(fakes.TICK_INTERVAL_S)
        return entries

    def settled(self, ended):
        """The log once `ended` exchanges have ended."""
        return self.logged(lambda entries: len(of(record.Ended, entries)) >= ended)

    def test_one_connection_carries_each_request_and_its_bytes(self):
        connection = http.client.HTTPConnection(LOOPBACK, self.port, timeout=SETTLE_TIMEOUT_S)
        connection.request('GET', '/json?b=2&a=1&a=3')
        connection.getresponse().read()
        connection.request('HEAD', '/json')
        connection.getresponse().read()
        connection.request('POST', '/json', body=b'x' * 1000)
        connection.getresponse().read()
        connection.close()
        entries = self.settled(3)
        self.assertEqual([(sent.method, sent.path, sent.query) for sent in of(record.Sent, entries)],
                         [('GET', '/json', ('a', 'b')), ('HEAD', '/json', ()), ('POST', '/json', ())])
        self.assertEqual([answered.status for answered in of(record.Answered, entries)], [200] * 3)
        ended = of(record.Ended, entries)
        self.assertEqual([end.ending for end in ended], [Ending.COMPLETE] * 3)
        self.assertGreater(ended[2].request_bytes, 1000)
        self.assertEqual(of(record.Fault, entries), [])

    def test_byte_counts_are_what_each_side_took(self):
        request = b'GET /json HTTP/1.1\r\nhost: 127.0.0.1:1\r\nConnection: close\r\n\r\n'
        received = self.exchange(request)
        self.assertTrue(received.startswith(b'HTTP/1.1 200'), received[:80])
        (ended,) = of(record.Ended, self.settled(1))
        self.assertEqual((ended.request_bytes, ended.response_bytes),
                         (len(self.forwarded(request)), len(received)))

    def test_pipelined_requests_are_answered_in_order(self):
        received = self.exchange(
            b'GET /json?first HTTP/1.1\r\nHost: test\r\n\r\n'
            b'GET /json?second HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n')
        entries = self.settled(2)
        self.assertEqual(received.count(b'HTTP/1.1 200'), 2)
        self.assertEqual([sent.query for sent in of(record.Sent, entries)], [('first',), ('second',)])
        self.assertEqual([end.ending for end in of(record.Ended, entries)], [Ending.COMPLETE] * 2)

    def test_trailers_and_a_bodyless_answer_keep_the_connection_in_step(self):
        connection = http.client.HTTPConnection(LOOPBACK, self.port, timeout=SETTLE_TIMEOUT_S)
        bodies = []
        for path in ('/trailers', '/empty', '/json'):
            connection.request('GET', path)
            bodies.append(connection.getresponse().read())
        connection.close()
        entries = self.settled(3)
        self.assertEqual(bodies[:2], [b'abc', b''])
        self.assertEqual([answered.status for answered in of(record.Answered, entries)],
                         [200, 204, 200])
        self.assertEqual([end.ending for end in of(record.Ended, entries)], [Ending.COMPLETE] * 3)

    def test_a_chunked_request_body_reaches_the_server_whole(self):
        request = (b'POST /json HTTP/1.1\r\nHost: test\r\nTransfer-Encoding: chunked\r\n'
                   b'Connection: close\r\n\r\n3\r\nabc\r\n2;x=y\r\nde\r\n0\r\nX-Trailer: 1\r\n\r\n')
        received = self.exchange(request)
        self.assertIn(b'"received": 5', received)
        (ended,) = of(record.Ended, self.settled(1))
        self.assertEqual((ended.ending, ended.request_bytes),
                         (Ending.COMPLETE, len(self.forwarded(request))))

    def test_an_interim_answer_reaches_the_client_before_the_request_body(self):
        head = (b'POST /json HTTP/1.1\r\nHost: test\r\nContent-Length: 4\r\n'
                b'Expect: 100-continue\r\nConnection: close\r\n\r\n')
        with self.connect() as client:
            client.sendall(head)
            interim = fakes.read_head(client)
            client.sendall(b'body')
            final = fakes.read_all(client)
        self.assertTrue(interim.startswith(b'HTTP/1.1 100'), interim)
        self.assertIn(b'"received": 4', final)
        entries = self.settled(1)
        self.assertEqual([answered.status for answered in of(record.Answered, entries)], [200])
        (ended,) = of(record.Ended, entries)
        self.assertEqual((ended.ending, ended.response_bytes),
                         (Ending.COMPLETE, len(interim) + len(final)))

    def test_a_switched_connection_relays_raw_bytes_both_ways(self):
        head = b'GET /upgrade HTTP/1.1\r\nHost: test\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n'
        with self.connect() as client:
            client.sendall(head)
            answer = fakes.read_head(client)
            client.sendall(b'ping')
            echoed = b''
            while len(echoed) < len(b'ping'):
                echoed += client.recv(len(b'ping') - len(echoed))
        self.assertEqual(echoed, b'ping')
        entries = self.settled(1)
        (answered,) = of(record.Answered, entries)
        self.assertEqual((answered.status, answered.stream), (101, True))
        (ended,) = of(record.Ended, entries)
        self.assertEqual((ended.ending, ended.detail), (Ending.SWITCHED, Ending.CLIENT_CLOSED.value))
        self.assertEqual((ended.request_bytes, ended.response_bytes),
                         (len(self.forwarded(head)) + len(b'ping'), len(answer) + len(b'ping')))

    def test_a_switch_the_request_did_not_ask_for_is_a_server_fault(self):
        received = self.exchange(b'GET /rogue-switch HTTP/1.1\r\nHost: test\r\n\r\n')
        entries = self.settled(1)
        self.assertEqual(received, b'')
        (fault,) = of(record.Fault, entries)
        self.assertEqual((fault.side, fault.detail), (http1.Side.SERVER, 'switched protocols unasked'))
        self.assertEqual(of(record.Ended, entries)[0].ending, Ending.MALFORMED)

    def test_chunked_event_stream_names_each_event(self):
        connection = http.client.HTTPConnection(LOOPBACK, self.port, timeout=SETTLE_TIMEOUT_S)
        connection.request('GET', '/chunked-events')
        connection.getresponse().read()
        connection.close()
        entries = self.settled(1)
        self.assertEqual([event.name for event in of(record.Arrived, entries)],
                         ['snapshot', events.COMMENT_EVENT, 'changed:lanes'])
        (answered,) = of(record.Answered, entries)
        self.assertEqual((answered.status, answered.stream), (200, True))
        self.assertEqual(of(record.Ended, entries)[0].ending, Ending.COMPLETE)

    def test_close_delimited_event_stream_ends_complete(self):
        self.exchange(b'GET /until-close-events HTTP/1.1\r\nHost: test\r\n\r\n')
        entries = self.settled(1)
        self.assertEqual([event.name for event in of(record.Arrived, entries)],
                         ['rpc:notifications/progress'])
        self.assertEqual(of(record.Ended, entries)[0].ending, Ending.COMPLETE)

    def test_a_client_leaving_a_stream_ends_it_without_a_fault(self):
        with self.connect() as client:
            client.sendall(b'GET /hold HTTP/1.1\r\nHost: test\r\n\r\n')
            client.recv(1024)
        entries = self.settled(1)
        (ended,) = of(record.Ended, entries)
        self.assertEqual(ended.ending, Ending.CLIENT_CLOSED)
        self.assertEqual([event for event in of(record.Arrived, entries) if event.t > ended.t], [])
        self.assertEqual(of(record.Fault, entries), [])

    def test_a_client_leaving_a_silent_stream_is_seen_at_once(self):
        with self.connect() as client:
            client.sendall(b'GET /idle HTTP/1.1\r\nHost: test\r\n\r\n')
            fakes.read_head(client)
        self.assertTrue(self.upstream.idle_closed.wait(SETTLE_TIMEOUT_S),
                        'the relay kept the server side open')
        (ended,) = of(record.Ended, self.settled(1))
        self.assertEqual(ended.ending, Ending.CLIENT_CLOSED)

    def test_a_request_the_client_gave_up_on_ends_when_the_client_leaves(self):
        request = b'GET /slow HTTP/1.1\r\nHost: test\r\n\r\n'
        for _ in range(3):
            with self.connect() as client:
                client.sendall(request)
        ended = of(record.Ended, self.settled(3))
        self.assertEqual([(end.ending, end.request_bytes, end.response_bytes) for end in ended],
                         [(Ending.CLIENT_CLOSED, len(self.forwarded(request)), 0)] * 3)

    def test_a_server_closing_an_idle_connection_closes_the_client_side(self):
        received = self.exchange(b'GET /linger HTTP/1.1\r\nHost: test\r\n\r\n')
        self.assertTrue(received.startswith(b'HTTP/1.1 200'), received[:80])
        entries = self.settled(1)
        (ended,) = of(record.Ended, entries)
        self.assertEqual((ended.ending, ended.response_bytes), (Ending.COMPLETE, len(received)))
        self.assertEqual(of(record.Fault, entries), [])

    def test_bytes_from_the_server_with_no_request_waiting_are_a_server_fault(self):
        received = self.exchange(b'GET /unasked HTTP/1.1\r\nHost: test\r\n\r\n')
        entries = self.logged(lambda entries: of(record.Fault, entries))
        self.assertNotIn(b'408', received)
        (fault,) = of(record.Fault, entries)
        self.assertEqual((fault.side, fault.detail), (http1.Side.SERVER, 'answer without a request'))
        self.assertEqual([end.ending for end in of(record.Ended, entries)], [Ending.COMPLETE])

    def test_a_server_cutting_a_chunked_stream_is_recorded_as_its_close(self):
        self.exchange(b'GET /cut HTTP/1.1\r\nHost: test\r\n\r\n')
        entries = self.settled(1)
        self.assertEqual([event.name for event in of(record.Arrived, entries)], ['first'])
        self.assertEqual(of(record.Ended, entries)[0].ending, Ending.SERVER_CLOSED)

    def test_a_request_it_cannot_frame_is_a_fault_and_never_reaches_the_server(self):
        self.exchange(b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n')
        entries = self.logged(lambda entries: of(record.Fault, entries))
        self.assertEqual(of(record.Sent, entries), [])
        self.assertEqual(of(record.Fault, entries)[0].side, http1.Side.CLIENT)

    def test_a_target_urlsplit_rejects_is_still_logged(self):
        self.exchange(b'GET //[ HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n')
        (sent,) = of(record.Sent, self.settled(1))
        self.assertEqual((sent.path, sent.query), ('//[', ()))

    def test_a_relay_error_in_a_connection_is_logged_and_ends_its_exchanges(self):
        with mock.patch.object(proxy, 'response_framing', side_effect=RuntimeError('boom')):
            received = self.exchange(b'GET /json HTTP/1.1\r\nHost: test\r\n\r\n')
            entries = self.settled(1)
        self.assertTrue(received.startswith(b'HTTP/1.1 200'), received[:80])
        self.assertEqual([failed.detail for failed in of(record.Failed, entries)],
                         ['RuntimeError: boom'])
        (ended,) = of(record.Ended, entries)
        self.assertEqual((ended.ending, ended.detail), (Ending.STOPPED, 'relay failed'))

    def test_an_error_the_event_loop_reports_is_logged(self):
        with mock.patch.object(proxy, 'Connection', side_effect=RuntimeError('boom')):
            self.exchange(b'GET /json HTTP/1.1\r\nHost: test\r\n\r\n')
            entries = self.logged(lambda entries: of(record.Failed, entries))
        self.assertEqual([failed.detail for failed in of(record.Failed, entries)],
                         ['RuntimeError: boom'])
        self.assertEqual(of(record.Sent, entries), [])


class Scripted:
    """An endpoint whose reads return at once, so both pumps are ready in the same step."""

    def __init__(self, side, heads, on_end=None):
        self.side = side
        self.heads = list(heads)
        self.on_end = on_end
        self.sent = []

    async def through(self, end):
        if self.heads:
            return self.heads.pop(0)
        if self.on_end is not None:
            self.on_end()
        return http1.Closed(self.side)

    async def send(self, data):
        self.sent.append(data)

    def close(self):
        pass


class ConnectionTest(unittest.TestCase):
    def test_the_side_that_stops_first_ends_the_connection_before_the_other_relays_more(self):
        log = record.Log()
        client = Scripted(http1.Side.CLIENT, [])
        server = Scripted(http1.Side.SERVER, [b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'])
        asyncio.run(proxy.Connection(log, b'', client, server).run())
        self.assertEqual((log.entries(), client.sent, server.heads),
                         ((), [], [b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n']))

    def test_a_tunnel_starts_on_101_or_on_a_2xx_answer_to_connect(self):
        loop = asyncio.new_event_loop()
        self.addCleanup(loop.close)
        upgrade = proxy.Exchange(1, 'GET', loop.create_future())
        connect = proxy.Exchange(2, 'CONNECT', loop.create_future())
        self.assertEqual([upgrade.switches(status) for status in (101, 200)], [True, False])
        self.assertEqual([connect.switches(status) for status in (200, 299, 300, 407)],
                         [True, True, False, False])
        self.assertFalse(proxy.Exchange(3, 'GET', None).switches(101))

    def test_the_ending_is_logged_before_the_relay_can_stop_the_connection(self):
        log = record.Log()

        async def scenario():
            tasks = []

            def stop_the_connection_next():
                # Runs inside the client pump. The relay stopping cancels the
                # connection one step after that pump ends.
                loop = asyncio.get_running_loop()
                pump = asyncio.current_task()
                assert pump is not None
                pump.add_done_callback(lambda _: loop.call_soon(tasks[0].cancel))
            client = Scripted(http1.Side.CLIENT, [b'GET / HTTP/1.1\r\nHost: x\r\n\r\n'],
                              stop_the_connection_next)
            server = Scripted(http1.Side.SERVER, [])
            tasks.append(asyncio.create_task(proxy.Connection(log, b'', client, server).run()))
            with contextlib.suppress(asyncio.CancelledError):
                await tasks[0]

        asyncio.run(scenario())
        self.assertEqual([ended.ending for ended in of(record.Ended, log.entries())],
                         [Ending.CLIENT_CLOSED])


class PipeTest(unittest.TestCase):
    def test_a_piece_counts_only_once_the_sink_took_it(self):
        class Gone:
            side = http1.Side.CLIENT

            async def send(self, data):
                return http1.Closed(self.side)
        heard = []
        pipe = proxy.Pipe(None, Gone(), heard.append, heard.append)
        self.assertEqual(asyncio.run(pipe.body(b'event')), http1.Closed(http1.Side.CLIENT))
        self.assertEqual(heard, [])


if __name__ == '__main__':
    unittest.main()
