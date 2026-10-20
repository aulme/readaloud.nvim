# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = [
#   "kokoro==0.9.4",
#   "sounddevice==0.5.1",
#   # Kokoro installs it with pip on first use otherwise, which uv envs lack.
#   "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl",
# ]
# ///
"""Reads text aloud with Kokoro for lua/readaloud/init.lua, and reports
each word as it's heard.

Commands come in on stdin, one JSON object per line:
  {"cmd": "read", "gen": 3, "voice": "af_heart", "speed": 1.0, "pause": 0.3,
   "paragraph_pause": 0.3, "paras": ["..."]}
  {"cmd": "pause"} | {"cmd": "resume"} | {"cmd": "stop"}
`pause` is the longest silence within a paragraph, and `paragraph_pause` the
silence between paragraphs, both in seconds.

Events go out on stdout, one JSON object per line:
  {"ready": true}                               the model has loaded
  {"gen": 3, "para": 0, "s": 12, "e": 17}       a word starts playing
  {"gen": 3, "done": true}                      the last word has played
`s` and `e` are byte offsets into the paragraph, so nvim can map them to
buffer positions. `gen` tells the events of a read apart from those of the
read it replaced.
"""

import collections
import json
import queue
import sys
import threading
import time

import numpy as np
import sounddevice as sd
from kokoro import KPipeline

RATE = 24000
# Kokoro is many times faster than speech, so a little audio in hand is enough,
# and a new read doesn't wait for a long backlog to be thrown away.
AHEAD_SECONDS = 20
FRAME = RATE // 100

events = queue.Queue()
lock = threading.Lock()
wake = threading.Condition(lock)
# Each segment is [gen, para, audio, word events, next event, position].
segments = collections.deque()
state = {"gen": 0, "paused": False, "job": None}
pipelines = {}


def emit(event):
    sys.stdout.write(json.dumps(event) + "\n")
    sys.stdout.flush()


def word_events(text, cursor, tokens):
    """Finds each spoken word in the paragraph, so its offset is the one nvim
    has. Kokoro keeps the words as written, eg `v2` or `on-prem`. A word it
    can't find nearby, eg one it expanded, is left out rather than moving the
    cursor."""
    found = []
    for token in tokens:
        if token.start_ts is None or not any(c.isalnum() for c in token.text):
            continue
        at = text.find(token.text, cursor)
        if at < 0 or at - cursor > 80:
            continue
        cursor = at + len(token.text)
        start = len(text[:at].encode())
        found.append((int(token.start_ts * RATE), start, start + len(token.text.encode())))
    return found, cursor


def squeeze(audio, found, pause):
    """Kokoro pauses long between sentences and leaves silence at both ends of
    each chunk it speaks. This cuts a silence longer than `pause` seconds down
    to it, half of it at each end of a chunk, and moves each word's start to
    match."""
    longest = int(RATE * pause)
    edge = longest // 2
    frames = len(audio) // FRAME
    loud = np.abs(audio[: frames * FRAME]).reshape(frames, FRAME).max(axis=1) > 0.01
    keep = np.ones(len(audio), dtype=bool)
    start = 0
    while start < frames:
        end = start
        while end < frames and not loud[end]:
            end += 1
        if end > start:
            first, last = start * FRAME, (end * FRAME if end < frames else len(audio))
            if first == 0:
                keep[first : max(first, last - edge)] = False
            elif last == len(audio):
                keep[first + edge : last] = False
            elif last - first > longest:
                keep[first + edge : last - edge] = False
        start = end + 1
    kept_before = np.concatenate(([0], np.cumsum(keep)))
    found = [(int(kept_before[min(at, len(audio))]), s, e) for at, s, e in found]
    return audio[keep], found


def synthesise():
    while True:
        with wake:
            while state["job"] is None:
                wake.wait()
            gen, voice, speed, pause, gap, paras = state["job"]
            state["job"] = None
        if voice[0] not in pipelines:
            pipelines[voice[0]] = KPipeline(lang_code=voice[0], repo_id="hexgrad/Kokoro-82M")
        pipeline = pipelines[voice[0]]
        for para, text in enumerate(paras):
            cursor = 0
            for result in pipeline(text, voice=voice, speed=speed):
                if state["gen"] != gen:
                    break
                audio = result.audio.numpy().astype(np.float32)
                found, cursor = word_events(text, cursor, result.tokens)
                audio, found = squeeze(audio, found, pause)
                with lock:
                    if state["gen"] != gen:
                        break
                    segments.append([gen, para, audio, found, 0, 0])
                while state["gen"] == gen and buffered() > AHEAD_SECONDS:
                    time.sleep(0.2)
            if state["gen"] != gen:
                break
            with lock:
                segments.append([gen, para, np.zeros(int(RATE * gap), dtype=np.float32), [], 0, 0])
        else:
            with lock:
                segments.append([gen, None, None, [], 0, 0])


def buffered():
    with lock:
        return sum(len(s[2]) - s[5] for s in segments if s[2] is not None) / RATE


def play(outdata, frames, _time, _status):
    outdata.fill(0)
    with lock:
        if state["paused"]:
            return
        filled = 0
        while filled < frames and segments:
            segment = segments[0]
            gen, para, audio, found = segment[:4]
            if audio is None:
                segments.popleft()
                events.put({"gen": gen, "done": True})
                continue
            take = min(frames - filled, len(audio) - segment[5])
            outdata[filled : filled + take, 0] = audio[segment[5] : segment[5] + take]
            segment[5] += take
            filled += take
            while segment[4] < len(found) and found[segment[4]][0] <= segment[5]:
                _, start, end = found[segment[4]]
                events.put({"gen": gen, "para": para, "s": start, "e": end})
                segment[4] += 1
            if segment[5] >= len(audio):
                segments.popleft()


def forward():
    while True:
        emit(events.get())


def main():
    pipelines["a"] = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
    threading.Thread(target=synthesise, daemon=True).start()
    threading.Thread(target=forward, daemon=True).start()
    stream = sd.OutputStream(samplerate=RATE, channels=1, dtype="float32", callback=play)
    stream.start()
    emit({"ready": True})
    for line in sys.stdin:
        command = json.loads(line)
        with wake:
            match command["cmd"]:
                case "read":
                    state["gen"] = command["gen"]
                    state["paused"] = False
                    segments.clear()
                    voice = command.get("voice", "af_heart")
                    state["job"] = (
                        command["gen"],
                        voice,
                        command.get("speed", 1.0),
                        command.get("pause", 0.3),
                        command.get("paragraph_pause", 0.3),
                        command["paras"],
                    )
                    wake.notify()
                case "pause":
                    state["paused"] = True
                case "resume":
                    state["paused"] = False
                case "stop":
                    state["gen"] += 1
                    segments.clear()
    stream.stop()


if __name__ == "__main__":
    main()
