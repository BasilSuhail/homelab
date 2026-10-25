#!/usr/bin/env python3
"""A Discord bot for the PC. Type `status` in the server and it answers with
right now, in a few plain lines (sudo pi-when status): which apps are
running, who is using what, how warm and busy the PC is, and any trouble in
the last day.

Config, root only: /etc/pi-bot/env, written by deploy/install-pi-bot.sh.

  DISCORD_BOT_TOKEN=...     from the Discord developer portal
  DISCORD_CHANNELS=123,456  optional: answer only in these channels
  JELLYFIN_API_KEY=...      optional: who is watching which film (read by
                            pi-when; without it, Tailscale viewers only)
  DISCORD_AI_CHANNEL=789    optional: a channel where every message goes to
                            the local AI (deploy/pi-ask.py, issue #200),
                            which looks at the PC read-only and answers

It connects out to Discord's gateway (a websocket, python3-websocket from
Debian) and listens there, so nothing on the PC is opened to the internet.
Runs as its own user, pi-bot. What needs root (pi-when, which reads k3s and
the journal, and pi-ask's checks) goes through one sudoers rule with fixed
arguments; see deploy/install-pi-bot.sh.
"""

import importlib.machinery
import json
import os
import random
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import websocket

API = "https://discord.com/api/v10"
GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json"
PI_WHEN = os.environ.get("PI_WHEN", "/usr/local/lib/pi/pi-when")
# Server messages, and their text. MESSAGE_CONTENT is a privileged intent:
# it has to be switched on under Bot in the developer portal, or the gateway
# closes with 4014.
INTENTS = (1 << 9) | (1 << 15)
# As its own user, through the one sudo rule install-pi-bot.sh writes for it.
COMMANDS = {"status": ([] if os.geteuid() == 0 else ["sudo", "-n"]) + [PI_WHEN, "status"]}
TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
CHANNELS = {c.strip() for c in os.environ.get("DISCORD_CHANNELS", "").split(",") if c.strip()}
AI_CHANNEL = os.environ.get("DISCORD_AI_CHANNEL", "").strip()
PI_ASK = os.environ.get("PI_ASK", "/usr/local/lib/pi/pi-ask")
# The last few exchanges, so "and the other drive?" makes sense. Kept short:
# the model's context is 8K tokens and every check's output shares it.
AI_MEMORY = 4
ai_state = {"history": [], "busy": threading.Lock()}
# Close codes that reconnecting will not fix; anything else is retried.
FATAL = {
    4004: "Discord refused the token. Run deploy/install-pi-bot.sh again with a fresh one.",
    4013: "Discord refused the intents.",
    4014: "Message Content Intent is off. Developer portal > the app > Bot > switch it on.",
}


class Closed(Exception):
    def __init__(self, code):
        super().__init__("closed with %s" % code)
        self.code = code


def log(msg):
    print(msg, flush=True)


def rest(method, path, body=None):
    req = urllib.request.Request(
        API + path, method=method, data=json.dumps(body).encode() if body is not None else b"",
        headers={"Authorization": "Bot " + TOKEN, "Content-Type": "application/json",
                 "User-Agent": "DiscordBot (pi-bot, 1)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()


def answer(msg, argv):
    channel = msg["channel_id"]
    try:
        rest("POST", "/channels/%s/typing" % channel)
    except (OSError, urllib.error.URLError):
        pass
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        text = out.stdout.strip() or out.stderr.strip() or "no answer"
    except subprocess.TimeoutExpired:
        text = "The PC took longer than a minute to answer."
    except OSError as err:
        text = "Could not ask the PC: %s" % err
    body = {"content": text[:1990], "allowed_mentions": {"parse": []},
            "message_reference": {"message_id": msg["id"], "fail_if_not_exists": False}}
    try:
        rest("POST", "/channels/%s/messages" % channel, body)
    except urllib.error.HTTPError as err:
        log("reply failed: %s %s" % (err.code, err.read()[:200]))
    except (OSError, urllib.error.URLError) as err:
        log("reply failed: %s" % err)


def reply(channel, msg_id, text):
    """Posts text in Discord-sized pieces, the first one as a reply."""
    chunks = [text[i:i + 1990] for i in range(0, len(text), 1990)] or ["(empty)"]
    for n, chunk in enumerate(chunks):
        body = {"content": chunk, "allowed_mentions": {"parse": []}}
        if n == 0:
            body["message_reference"] = {"message_id": msg_id, "fail_if_not_exists": False}
        try:
            rest("POST", "/channels/%s/messages" % channel, body)
        except urllib.error.HTTPError as err:
            log("reply failed: %s %s" % (err.code, err.read()[:200]))
        except (OSError, urllib.error.URLError) as err:
            log("reply failed: %s" % err)


def ask_ai(msg):
    channel, question = msg["channel_id"], msg.get("content", "").strip()
    if question.lower() in ("reset", "new", "forget"):
        ai_state["history"].clear()
        reply(channel, msg["id"], "Started fresh.")
        return
    if not ai_state["busy"].acquire(blocking=False):
        reply(channel, msg["id"], "Still working on the last question.")
        return
    done = threading.Event()

    def typing():
        # Discord shows "typing" for ten seconds per call.
        while not done.is_set():
            try:
                rest("POST", "/channels/%s/typing" % channel)
            except (OSError, urllib.error.URLError):
                pass
            done.wait(8)

    threading.Thread(target=typing, daemon=True).start()
    checked = []
    try:
        ask = importlib.machinery.SourceFileLoader("pi_ask", PI_ASK).load_module().ask
        answer_text = ask(question, list(ai_state["history"]), on_check=checked.append)
    except (OSError, ImportError, SyntaxError) as err:
        answer_text = "The AI part is not installed: %s" % err
    finally:
        done.set()
        ai_state["busy"].release()
    ai_state["history"] = (ai_state["history"] + [(question, answer_text)])[-AI_MEMORY:]
    if checked:
        answer_text += "\n-# looked at: " + ", ".join(dict.fromkeys(checked))
    reply(channel, msg["id"], answer_text)


def on_message(msg):
    if msg.get("author", {}).get("bot") or not msg.get("guild_id"):
        return
    if AI_CHANNEL and msg["channel_id"] == AI_CHANNEL:
        if msg.get("content", "").strip():
            log("%s asked the AI" % msg.get("author", {}).get("username", "?"))
            threading.Thread(target=ask_ai, args=(msg,), daemon=True).start()
        return
    if CHANNELS and msg["channel_id"] not in CHANNELS:
        return
    argv = COMMANDS.get(msg.get("content", "").strip().lower().lstrip("!/"))
    if argv:
        log("%s asked for %s" % (msg.get("author", {}).get("username", "?"), argv[-1]))
        threading.Thread(target=answer, args=(msg, argv), daemon=True).start()


def receive(ws):
    """The next event, or Closed with Discord's close code."""
    while True:
        opcode, data = ws.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise Closed(int.from_bytes(data[:2], "big") if len(data) >= 2 else None)
        if opcode == websocket.ABNF.OPCODE_TEXT:
            return json.loads(data)


def session():
    ws = websocket.create_connection(GATEWAY, timeout=30)
    stop = threading.Event()
    try:
        interval = receive(ws)["d"]["heartbeat_interval"] / 1000
        # Heartbeat answers arrive every interval; two without anything at all
        # means the connection is gone even if the socket has not noticed.
        ws.settimeout(interval * 2)
        state = {"seq": None, "acked": True}

        def beat():
            stop.wait(interval * random.random())
            while not stop.is_set():
                if not state["acked"]:
                    log("Discord stopped answering heartbeats; reconnecting")
                    ws.close()
                    return
                state["acked"] = False
                try:
                    ws.send(json.dumps({"op": 1, "d": state["seq"]}))
                except websocket.WebSocketException:
                    return
                stop.wait(interval)

        threading.Thread(target=beat, daemon=True).start()
        ws.send(json.dumps({"op": 2, "d": {"token": TOKEN, "intents": INTENTS,
                                           "properties": {"os": "linux", "browser": "pi-bot", "device": "pi-bot"}}}))
        while True:
            event = receive(ws)
            if event.get("s") is not None:
                state["seq"] = event["s"]
            op = event.get("op")
            if op == 11:
                state["acked"] = True
            elif op == 1:
                ws.send(json.dumps({"op": 1, "d": state["seq"]}))
            elif op in (7, 9):
                log("Discord asked for a new connection")
                return
            elif op == 0 and event.get("t") == "READY":
                log("connected as %s" % event["d"]["user"]["username"])
            elif op == 0 and event.get("t") == "MESSAGE_CREATE":
                on_message(event["d"])
    finally:
        stop.set()
        ws.close()


def main():
    if not TOKEN:
        sys.exit("no DISCORD_BOT_TOKEN in /etc/pi-bot/env; run deploy/install-pi-bot.sh")
    delay = 5
    while True:
        started = time.time()
        try:
            session()
        except Closed as err:
            if err.code in FATAL:
                # Waiting rather than exiting, so fixing it in the portal is
                # picked up without touching the PC.
                log(FATAL[err.code] + " Trying again in 10 minutes.")
                time.sleep(600)
                continue
            log("Discord closed the connection (%s); reconnecting" % err.code)
        except (OSError, ValueError, KeyError, websocket.WebSocketException) as err:
            log("connection lost (%s); reconnecting" % err)
        delay = 5 if time.time() - started > 60 else min(delay * 2, 300)
        time.sleep(delay)


if __name__ == "__main__":
    main()
