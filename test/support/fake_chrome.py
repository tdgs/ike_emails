"""A stand-in for Chrome in the tests of IkeEmails.Chrome, see test/support/fake_chrome.ex.

It talks the pipe protocol of --remote-debugging-pipe: JSON commands that end with a
NUL byte are read from file descriptor 3, and replies and events are written to file
descriptor 4 in the same way. It ends when the pipe is closed, as Chrome does.

The answer to Runtime.evaluate depends on a marker in the expression:

  FAKE:ECHO      the expression itself, as the value
  FAKE:PARAMS    the flags of the command: awaitPromise, userGesture, returnByValue, sessionId
  FAKE:THROW     an exception at line 3, column 7, whose text repeats the expression
  FAKE:NEVER     no answer
  FAKE:SLOW      the answer comes after 0.4 seconds
  FAKE:SPLIT     the answer is written in pieces, with a pause between them
  FAKE:EXIT      the process ends without an answer
  FAKE:CONSOLE   a console event comes with the answer, in the same write
  FAKE:ENV       the environment of the process, as the value
  FAKE:ARGV      the arguments of the process
  FAKE:PID       the id of the process
  FAKE:OBJECT    an object that is not returned by value, when returnByValue is false
  FAKE:UNDEFINED undefined

and any other is the number 42. The answer to Page.navigate depends on the address:
"fail" cannot be loaded, "same-document" stays on the document, "never" does not
load, "early" loads before it answers; any other loads after a stale load event.

It keeps the browser contexts as Chrome does: Target.createBrowserContext makes one,
Target.createTarget takes its id, Target.disposeBrowserContext closes the targets in
it, and Target.getBrowserContexts and Target.getTargets tell what is open. The command
Fake.failNext, with the method to fail as {"method": ...}, makes the next command of
that method fail with the code -32000, which no real Chrome has.
"""

import json
import os
import sys
import threading
import time

PIPE_IN = 3
PIPE_OUT = 4

write_lock = threading.Lock()
counters = {"target": 0, "session": 0, "loader": 0, "context": 0}
session_of_target = {}
closed_sessions = set()
# The targets that are open, with the browser context of each: None for the default one
targets = {}
contexts = set()
failing = set()


def frame(message):
    return json.dumps(message, ensure_ascii=False).encode("utf-8") + b"\0"


def write_all(data):
    with write_lock:
        try:
            while data:
                written = os.write(PIPE_OUT, data)
                data = data[written:]
        except OSError:
            os._exit(0)


def send(*messages):
    write_all(b"".join(frame(message) for message in messages))


def later(seconds, action):
    timer = threading.Timer(seconds, action)
    timer.daemon = True
    timer.start()


def lifecycle(session, loader, name="load"):
    params = {"frameId": "FRAME", "loaderId": loader, "name": name, "timestamp": 1.0}
    return {"method": "Page.lifecycleEvent", "params": params, "sessionId": session}


def value(kind, content):
    return {"result": {"type": kind, "value": content}}


def evaluate(params, session):
    expression = params.get("expression", "")

    if "FAKE:NEVER" in expression:
        return None
    if "FAKE:EXIT" in expression:
        os._exit(3)
    if "FAKE:THROW" in expression:
        text = "Error: " + expression
        exception = {"type": "object", "subtype": "error", "description": text}
        return {
            "result": exception,
            "exceptionDetails": {
                "exceptionId": 1,
                "text": "Uncaught",
                "lineNumber": 3,
                "columnNumber": 7,
                "exception": exception,
            },
        }
    if "FAKE:ECHO" in expression:
        return value("string", expression)
    if "FAKE:PARAMS" in expression:
        flags = {
            "awaitPromise": params.get("awaitPromise"),
            "userGesture": params.get("userGesture"),
            "returnByValue": params.get("returnByValue"),
            "sessionId": session,
        }
        return value("object", flags)
    if "FAKE:ENV" in expression:
        return value("object", dict(os.environ))
    if "FAKE:ARGV" in expression:
        return value("object", sys.argv[1:])
    if "FAKE:PID" in expression:
        return value("number", os.getpid())
    if "FAKE:UNDEFINED" in expression:
        return {"result": {"type": "undefined"}}
    if "FAKE:OBJECT" in expression and not params.get("returnByValue"):
        return {"result": {"type": "object", "className": "Object", "objectId": "OBJECT-1"}}
    return value("number", 42)


def close_target(target_id):
    """Forgets the target. The events to send for it: its session is gone."""
    targets.pop(target_id, None)
    gone = session_of_target.pop(target_id, None)
    if gone is None:
        return []
    closed_sessions.add(gone)
    return [{"method": "Target.detachedFromTarget", "params": {"sessionId": gone}}]


def navigate(params, session, reply):
    url = params.get("url", "")
    counters["loader"] += 1
    loader = "LOADER-%d" % counters["loader"]

    if "fail" in url:
        return reply({"frameId": "FRAME", "errorText": "net::ERR_NAME_NOT_RESOLVED"})
    if "same-document" in url:
        return reply({"frameId": "FRAME"})

    answer = {"frameId": "FRAME", "loaderId": loader}
    stale = lifecycle(session, "LOADER-OLD")

    if "early" in url:
        send(stale, lifecycle(session, loader), reply(answer, send_it=False))
    elif "never" in url:
        send(stale, reply(answer, send_it=False))
    else:
        send(stale, reply(answer, send_it=False))
        later(0.1, lambda: send(lifecycle(session, loader)))


def handle(message):
    method = message["method"]
    params = message.get("params") or {}
    session = message.get("sessionId")

    def reply(result, send_it=True):
        body = {"id": message["id"], "result": result}
        if session:
            body["sessionId"] = session
        if send_it:
            send(body)
        return body

    def failure(code, text):
        send({"id": message["id"], "error": {"code": code, "message": text}})

    if session in closed_sessions:
        return failure(-32001, "Session with given id not found.")

    if method in failing:
        failing.discard(method)
        return failure(-32000, "Failed on purpose")
    if method == "Fake.failNext":
        failing.add(params["method"])
        return reply({})
    if method == "Target.createBrowserContext":
        counters["context"] += 1
        context = "CONTEXT-%d" % counters["context"]
        contexts.add(context)
        return reply({"browserContextId": context})
    if method == "Target.disposeBrowserContext":
        context = params.get("browserContextId")
        if context not in contexts:
            return failure(-32602, "Failed to find context with id %s" % context)
        contexts.discard(context)
        doomed = [target for target, owner in targets.items() if owner == context]
        events = [event for target in doomed for event in close_target(target)]
        return send(*events, reply({}, send_it=False))
    if method == "Target.getBrowserContexts":
        return reply({"browserContextIds": sorted(contexts)})
    if method == "Target.getTargets":
        infos = [
            {"targetId": target, "type": "page", "browserContextId": owner or "DEFAULT"}
            for target, owner in targets.items()
        ]
        return reply({"targetInfos": infos})
    if method == "Target.createTarget":
        context = params.get("browserContextId")
        if context is not None and context not in contexts:
            return failure(-32602, "Failed to find browser context with id %s" % context)
        counters["target"] += 1
        target = "TARGET-%d" % counters["target"]
        targets[target] = context
        return reply({"targetId": target})
    if method == "Target.attachToTarget":
        if params.get("targetId") not in targets:
            return failure(-32602, "No target with given id found")
        counters["session"] += 1
        attached = "SESSION-%d" % counters["session"]
        session_of_target[params["targetId"]] = attached
        return reply({"sessionId": attached})
    if method == "Target.closeTarget":
        if params.get("targetId") not in targets:
            return failure(-32602, "No target with given id found")
        return send(*close_target(params["targetId"]), reply({"success": True}, send_it=False))
    if method in ("Runtime.enable", "Page.enable", "Page.setLifecycleEventsEnabled"):
        return reply({})
    if method == "Browser.getVersion":
        return reply({"product": "FakeChrome/1", "protocolVersion": "1.3"})
    if method == "Browser.close":
        send({"id": message["id"], "result": {}})
        os._exit(0)
    if method == "Page.navigate":
        return navigate(params, session, reply)
    if method == "Runtime.evaluate":
        return runtime_evaluate(message, params, session, reply)

    failure(-32601, "'%s' wasn't found" % method)


def runtime_evaluate(message, params, session, reply):
    expression = params.get("expression", "")
    result = evaluate(params, session)
    if result is None:
        return

    if "FAKE:SLOW" in expression:
        return later(0.4, lambda: reply(result))

    if "FAKE:CONSOLE" in expression:
        arguments = [{"type": "string", "value": "[crawler] hello"}]
        console = {
            "method": "Runtime.consoleAPICalled",
            "params": {"type": "log", "args": arguments},
            "sessionId": session,
        }
        return send(console, reply(result, send_it=False))

    if "FAKE:SPLIT" in expression:
        data = frame(reply(result, send_it=False))
        third = len(data) // 3
        for piece in (data[:third], data[third : 2 * third], data[2 * third :]):
            write_all(piece)
            time.sleep(0.05)
        return

    reply(result)


def main():
    pending = b""
    while True:
        chunk = os.read(PIPE_IN, 65536)
        if not chunk:
            os._exit(0)
        *complete, pending = (pending + chunk).split(b"\0")
        for raw in complete:
            if raw:
                handle(json.loads(raw))


main()
