# 진동 실험실 효과음 만들기: 짧은 wav 몇 개 (외부 소리 파일 없이 생성)
import math, random, struct, sys, wave
out = sys.argv[1]
def write(name, samples, rate=22050):
    with wave.open(f"{out}/{name}", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 30000)) for s in samples))
def tone(f0, f1, sec, noise=0.0, rate=22050):
    n = int(sec * rate); ph = 0.0; r = random.Random(1)
    for i in range(n):
        t = i / n; f = f0 + (f1 - f0) * t; ph += 2 * math.pi * f / rate
        yield (math.sin(ph) * (1 - noise) + (r.random() * 2 - 1) * noise) * (1 - t) ** 2
write("lab_hit.wav", tone(220, 60, 0.18, noise=0.5))
write("lab_strong.wav", tone(160, 40, 0.3, noise=0.7))
write("lab_faint.wav", tone(400, 80, 0.6))
write("lab_shake.wav", tone(700, 500, 0.08))
write("lab_beep.wav", tone(880, 880, 0.08))
for n in ("lab_sharp0.wav", "lab_sharp50.wav", "lab_sharp100.wav"):
    write(n, tone(600, 600, 0.05))
