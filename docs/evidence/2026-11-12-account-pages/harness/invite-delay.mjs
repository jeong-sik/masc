// A stand-in in front of an account server, for the invitation page. It
// passes every request on to the server, with two exceptions:
//   - GET /__stand_in/hold?ms=N makes it hold the answer of the next
//     GET /accounts/invite for N ms, the way a slow network does;
//   - POST /auth/github/start it answers itself with a short page, so a press
//     of the button goes nowhere past this machine.
// GET /__stand_in answers what it saw: how many times the invitation page was
// asked for, and the invite value of each start, in order.
// usage: node invite-delay.mjs SERVER_PORT PORT
import http from "node:http";

const [serverPort, port] = process.argv.slice(2).map(Number);
const seen = { invitePages: 0, starts: [] };
let holdMs = 0;

const read = (request) =>
  new Promise((resolve, reject) => {
    const parts = [];
    request.on("data", (part) => parts.push(part));
    request.on("end", () => resolve(Buffer.concat(parts)));
    request.on("error", reject);
  });

const answer = (response, status, type, text) => {
  response.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  response.end(text);
};

// The server answers only requests that name it in Host, so the stand-in
// names the server there. The browser drops an answer it no longer waits for,
// such as the held page after a press sent the form; the stand-in lets that go.
const pass = (request, response, payload) => {
  response.on("error", () => {});
  const headers = { ...request.headers, host: `127.0.0.1:${serverPort}` };
  const ahead = http.request(
    { host: "127.0.0.1", port: serverPort, method: request.method, path: request.url, headers },
    (reply) => {
      response.writeHead(reply.statusCode, reply.headers);
      reply.pipe(response);
    },
  );
  ahead.on("error", () => answer(response, 502, "text/plain", "the server did not answer"));
  ahead.end(payload);
};

http
  .createServer(async (request, response) => {
    const payload = await read(request);
    const url = new URL(request.url, "http://stand-in");
    if (request.method === "GET" && url.pathname === "/__stand_in") {
      answer(response, 200, "application/json", JSON.stringify(seen));
    } else if (request.method === "GET" && url.pathname === "/__stand_in/hold") {
      holdMs = Number(url.searchParams.get("ms"));
      answer(response, 200, "application/json", JSON.stringify({ holdMs }));
    } else if (request.method === "POST" && url.pathname === "/auth/github/start") {
      seen.starts.push(new URLSearchParams(payload.toString("utf8")).get("invite"));
      answer(response, 200, "text/html; charset=utf-8", "<!doctype html><title>start</title><p>The stand-in took the start.</p>");
    } else {
      if (request.method === "GET" && url.pathname === "/accounts/invite") {
        seen.invitePages += 1;
        const wait = holdMs;
        holdMs = 0;
        if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      }
      pass(request, response, payload);
    }
  })
  .listen(port, "127.0.0.1", () => console.log(`stand-in on ${port} in front of ${serverPort}`));
