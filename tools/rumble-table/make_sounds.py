# 진동 1차 표 시험: Essentials 효과음 이름 그대로인 짧은 wav (외부 소리 파일 없이 생성)
# 이름이 base-essentials 표와 같아서, 게임 표 없이 "포켓몬 공통 기본 표" 로 울린다
import math, random, struct, sys, wave

out = sys.argv[1]
RATE = 22050


def write(name, samples):
    with wave.open(f"{out}/{name}.wav", "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 30000)) for s in samples))


def tone(f0, f1, sec, noise=0.0, decay=2.0, seed=1):
    n = int(sec * RATE); ph = 0.0; r = random.Random(seed)
    for i in range(n):
        t = i / n; f = f0 + (f1 - f0) * t; ph += 2 * math.pi * f / RATE
        yield (math.sin(ph) * (1 - noise) + (r.random() * 2 - 1) * noise) * (1 - t) ** decay


def chain(*parts):
    for p in parts:
        yield from p


def rest(sec):
    return (0.0 for _ in range(int(sec * RATE)))


write("Battle damage weak", tone(300, 150, 0.12, noise=0.4))
write("Battle damage normal", tone(220, 70, 0.2, noise=0.55))
write("Battle damage super", tone(160, 40, 0.35, noise=0.7, decay=1.5))
write("Pkmn faint", tone(500, 70, 0.6, decay=1.2))
write("Battle throw", tone(400, 1200, 0.15, noise=0.3))
write("Battle critical catch throw", chain(tone(500, 1500, 0.15, noise=0.3), tone(1500, 1500, 0.08)))
write("Battle ball hit", tone(900, 300, 0.07, noise=0.5))
write("Battle jump to ball", tone(1200, 300, 0.25, noise=0.2))
write("Battle ball drop", tone(600, 200, 0.08, noise=0.4))
write("Battle ball shake", tone(700, 500, 0.09, noise=0.3))
write("Battle catch click", chain(tone(2000, 1800, 0.04, noise=0.5), rest(0.05), tone(880, 880, 0.25, decay=1)))
write("Battle recall", tone(800, 1400, 0.18, noise=0.2))
write("Battle flee", tone(600, 200, 0.3, noise=0.6))
write("Pkmn level up", chain(tone(660, 660, 0.1, decay=0.5), tone(880, 880, 0.1, decay=0.5), tone(1320, 1320, 0.2)))
write("GUI sel cursor", tone(1000, 1000, 0.04))
