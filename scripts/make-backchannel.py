#!/usr/bin/env python3
"""Generates the backchannel sounds (相槌) with Gemini TTS.

This is how Resources/backchannel was made, and how to make your own set in another voice:

    GEMINI_API_KEY=... python3 scripts/make-backchannel.py [--voice Sulafat] [--out DIR]

DIR defaults to ~/Library/Application Support/Unazc/backchannel, which the app prefers over the
bundled set while it holds any sound. The file name's prefix says when each one plays:

    ack-*   after an ordinary pause          (うん / はい)
    cont-*  after a long stretch of talking  (うんうん / なるほど)
    q-*     after a rising, question ending  (うーん; plain うん too, from ack-)

Your own recordings work the same way (any format AVAudioPlayer reads). Listen to what comes out:
the model sometimes says something else, so drop the takes that are wrong.
"""
import argparse, array, base64, io, json, os, re, sys, urllib.request, wave

MODEL = "gemini-3.8-flash-tts"
# The model speaks this instruction aloud too, before the reply; `last_utterance` keeps the reply.
STYLE = "Say quietly and warmly, like a friend listening on the phone: "
# (file name, text, takes)
SOUNDS = [
    ("ack-un", "うん。", 2), ("ack-ee", "ええ。", 2), ("ack-hai", "はい。", 2),
    ("ack-aa", "あー、うん。", 1), ("ack-sokka", "そっか。", 2),
    ("cont-unun", "うんうん。", 2), ("cont-hee", "へぇ。", 2), ("cont-naruhodo", "なるほど。", 2),
    ("cont-naruhodone", "なるほどね。", 1), ("cont-soudanda", "そうなんだ。", 2),
    ("cont-fuun", "ふーん。", 1), ("cont-tashikani", "たしかに。", 1),
    ("q-uun", "うーん。", 2),
]


def synthesize(key, voice, text):
    body = {"contents": [{"parts": [{"text": STYLE + text}]}],
            "generationConfig": {"responseModalities": ["AUDIO"],
                                 "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}}}}
    req = urllib.request.Request(f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "x-goog-api-key": key})
    part = json.load(urllib.request.urlopen(req, timeout=180))["candidates"][0]["content"]["parts"][0]["inlineData"]
    raw = base64.b64decode(part["data"])
    if raw[:4] == b"RIFF":  # some responses are a whole WAV file, others bare 16-bit mono PCM
        with wave.open(io.BytesIO(raw)) as w:
            if w.getnchannels() != 1 or w.getsampwidth() != 2:
                raise ValueError(f"unexpected WAV: {w.getnchannels()} channels, {w.getsampwidth() * 8} bit")
            return w.getframerate(), array.array("h", w.readframes(w.getnframes()))
    rate = re.search(r"rate=(\d+)", part.get("mimeType", ""))
    return int(rate.group(1)) if rate else 24000, array.array("h", raw)


def drop_end_noise(rate, samples):
    """Gemini ends every reply with about 0.12 s of loud hiss after a short silence; cuts it off.
    Only a burst of at most 0.3 s that reaches the very end, follows 0.1 s of silence and is that
    hiss counts: far louder than speech (about -6 dBFS RMS) and crossing zero more often than a voice."""
    win, loud = rate // 100, 1000  # about -30 dBFS; the silence before it sits near -60
    levels = [max(map(abs, samples[i:i + win]), default=0) for i in range(0, len(samples), win)]
    end = len(levels)
    while end > 0 and levels[end - 1] > loud:
        end -= 1
    if end == len(levels) or (len(levels) - end) * win > rate * 0.3:
        return samples
    quiet = end
    while quiet > 0 and levels[quiet - 1] <= loud:
        quiet -= 1
    if (end - quiet) * win < rate * 0.1:
        return samples
    burst = samples[end * win:]
    crossings = sum(1 for a, b in zip(burst, burst[1:]) if (a < 0) != (b < 0)) / len(burst)
    rms = (sum(v * v for v in burst) / len(burst)) ** 0.5
    # Measured: the hiss crosses at about 0.18 and sits near -6 dBFS; replies reach about 0.10 and
    # stay well under -12 dBFS, so both have to hold.
    if crossings < 0.14 or rms < 32768 * 10 ** (-12 / 20):
        return samples
    return samples[:end * win]


def last_utterance(rate, samples):
    """The last stretch of sound after a gap of 0.45 s or more, with 30 ms before and 80 ms after.
    If it is under 0.08 s (a click) the take fails, rather than falling back to the spoken
    instruction before it."""
    samples = drop_end_noise(rate, samples)
    peak = max(map(abs, samples), default=0)
    if not peak:
        raise ValueError("no sound")
    win = rate // 100
    active = [i for i in range(0, len(samples), win) if max(map(abs, samples[i:i + win])) > peak * 0.04]
    stretches = []
    for i in active:
        if stretches and i - stretches[-1][1] <= rate * 0.45:
            stretches[-1][1] = i
        else:
            stretches.append([i, i])
    start, end = stretches[-1]
    if end + win - start < rate * 0.08:
        raise ValueError("the last sound is a click, not a reply")
    out = samples[max(0, start - rate * 3 // 100):min(len(samples), end + win + rate * 8 // 100)]
    fade = rate // 50
    for i in range(min(fade, len(out))):
        out[-1 - i] = int(out[-1 - i] * i / fade)
    return out


def normalize(samples, rms_db=-17.0, peak_db=-1.0):
    """Every take at the same loudness (RMS of the louder half), so no reply jumps out; the peak
    is kept under `peak_db`."""
    levels = sorted(abs(v) for v in samples)
    loud = [v for v in levels[len(levels) // 2:]] or [0]
    rms = (sum(v * v for v in loud) / len(loud)) ** 0.5 or 1
    gain = min(32768 * 10 ** (rms_db / 20) / rms, 32767 * 10 ** (peak_db / 20) / (levels[-1] or 1))
    return array.array("h", (max(-32768, min(32767, int(v * gain))) for v in samples))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="Sulafat")
    ap.add_argument("--out", default=os.path.expanduser("~/Library/Application Support/Unazc/backchannel"))
    args = ap.parse_args()
    key = os.environ.get("GEMINI_API_KEY") or sys.exit("set GEMINI_API_KEY")
    os.makedirs(args.out, exist_ok=True)
    failed = []
    for name, text, takes in SOUNDS:
        for take in range(1, takes + 1):
            path = os.path.join(args.out, f"{name}-{take}.wav")
            try:
                rate, samples = synthesize(key, args.voice, text)
                clip = normalize(last_utterance(rate, samples))
            except Exception as e:  # one bad take should not stop the rest
                print(f"{path}: {text} failed: {e}", file=sys.stderr)
                failed.append(path)
                continue
            # Written under a name the app ignores, then renamed: the app only ever sees whole
            # files, and the rename changes the folder's date, which is what makes it reload.
            tmp = os.path.join(args.out, f".{name}-{take}.wav.tmp")
            with wave.open(tmp, "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(clip.tobytes())
            os.replace(tmp, path)
            print(f"{path}: {text} {len(clip) / rate:.2f}s")
    if failed:
        sys.exit(f"{len(failed)} takes failed; run again to retry them")

if __name__ == "__main__":
    main()
