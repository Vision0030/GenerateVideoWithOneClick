#!/usr/bin/env python3
# 合成节拍卡点伴奏，用于"一键成片"模板的 BGM 与卡点对齐。
# 纯标准库实现：kick / snare / hat / bass / arpeggio / pad，输出 16bit 立体声 WAV，
# 可选调用 macOS 自带的 afconvert 转成 m4a（模板音频统一用 m4a）。
#
# 用法:
#   python3 make_bgm.py --bpm 128 --style fast --out /tmp/bgm.wav
#   python3 make_bgm.py --bpm 90  --style calm --out /tmp/bgm.wav --m4a bgm_daily_90bpm.m4a
import argparse, math, os, random, shutil, struct, subprocess, wave

SR = 44100
TAIL = 0.4

# 每种风格决定鼓组密度、琶音密度与贝斯步进，slow 用更稀疏的织体
STYLES = {
    "fast": {"kick_beats": [0, 1, 2, 3], "snare_beats": [1, 3], "hat_div": 2, "arp_div": 2, "bass_div": 1.0},
    "calm": {"kick_beats": [0, 2],       "snare_beats": [1, 3], "hat_div": 1, "arp_div": 1, "bass_div": 2.0},
    "hype": {"kick_beats": [0, 1, 2, 3], "snare_beats": [1, 3], "hat_div": 4, "arp_div": 4, "bass_div": 0.5},
}

# 每小节一个和弦：Am F C G，循环
CHORDS = [
    {"root": 110.00, "tones": [220.00, 261.63, 329.63, 440.00]},  # Am
    {"root":  87.31, "tones": [174.61, 220.00, 261.63, 349.23]},  # F
    {"root": 130.81, "tones": [196.00, 261.63, 329.63, 392.00]},  # C (第二转位)
    {"root":  98.00, "tones": [196.00, 246.94, 293.66, 392.00]},  # G
]

ARP_SEQ = [0, 1, 2, 3, 1, 2, 3, 0]


def env_pluck(t, k):      # 指数衰减包络
    return math.exp(-t * k)


def kick(t):
    f = 150.0 * math.exp(-t * 18.0) + 48.0
    return math.sin(2 * math.pi * f * t) * math.exp(-t * 11.0)


def make_snare():
    rnd = random.Random(7)

    def g(t):
        noise = rnd.random() - 0.5
        return noise * math.exp(-t * 22.0) + 0.4 * math.sin(2 * math.pi * 190 * t) * math.exp(-t * 30.0)
    return g


def make_hat():
    rnd = random.Random(23)
    prev = [0.0]

    def g(t):
        x = rnd.random() - 0.5
        hp = x - prev[0]   # 一阶差分近似高通
        prev[0] = x
        return hp * math.exp(-t * 60.0)
    return g


def make_bass(f):
    def g(t):
        a = 1.0 if t < 0.004 else 0.35  # 简化 attack
        return (math.sin(2 * math.pi * f * t) + 0.35 * math.sin(4 * math.pi * f * t)
                + 0.12 * math.sin(6 * math.pi * f * t)) * env_pluck(t, 2.2) * a
    return g


def make_arp(f):
    def g(t):
        return (math.sin(2 * math.pi * f * t) + 0.25 * math.sin(4 * math.pi * f * t)
                + 0.1 * math.sin(6 * math.pi * f * t)) * env_pluck(t, 7.0)
    return g


def make_pad(freqs):
    def g(t):
        v = 0.0
        for f in freqs:
            v += math.sin(2 * math.pi * f * t + f)
        return v / len(freqs)
    return g


def render(bpm, bars, style):
    beat = 60.0 / bpm
    st = STYLES[style]
    total = bars * 4 * beat + TAIL
    n = int(total * SR)
    mono = [0.0] * n

    def add_note(start, dur, amp, gen):
        s0 = int(start * SR)
        cnt = min(int(dur * SR), n - s0)
        for i in range(cnt):
            mono[s0 + i] += gen(i / SR) * amp

    for bar in range(bars):
        ch = CHORDS[bar % 4]
        bar_t = bar * 4 * beat
        snare, hat = make_snare(), make_hat()
        # 打鼓
        for b in st["kick_beats"]:
            add_note(bar_t + b * beat, 0.16, 0.95, kick)
        for b in st["snare_beats"]:
            add_note(bar_t + b * beat, 0.12, 0.5, snare)
        hat_div = st["hat_div"]
        for k in range(int(4 * hat_div)):
            amp = 0.16 if k % hat_div == 0 else 0.10
            add_note(bar_t + k * beat / hat_div, 0.04, amp, hat)
        # 贝斯：按风格步进铺根音
        step = beat * st["bass_div"]
        for k in range(int(4 / st["bass_div"])):
            add_note(bar_t + k * step + 0.01, step * 0.88, 0.5, make_bass(ch["root"]))
        # 琶音
        arp_div = st["arp_div"]
        arp_steps = int(4 * arp_div)
        for s in range(arp_steps):
            f = ch["tones"][ARP_SEQ[s % len(ARP_SEQ)]]
            add_note(bar_t + s * beat / arp_div, 0.22 * 2 / arp_div, 0.17, make_arp(f))
        # 铺底
        add_note(bar_t, 4 * beat, 0.045, make_pad([ch["root"] * 2, ch["tones"][1], ch["tones"][2]]))

    # 归一化 + 首尾淡化
    peak = max(abs(v) for v in mono)
    gain = 0.89 / peak
    fade_in, fade_out = int(0.02 * SR), int(0.5 * SR)
    for i in range(n):
        v = mono[i] * gain
        if i < fade_in:
            v *= i / fade_in
        if i > n - fade_out:
            v *= (n - i) / fade_out
        mono[i] = v

    # 输出立体声（用极短延迟制造宽度）
    delay = int(0.0004 * SR)
    frames = bytearray()
    for i in range(n):
        l = mono[i]
        r = mono[i - delay] if i >= delay else 0.0
        frames += struct.pack('<hh', int(max(-1, min(1, l)) * 32767), int(max(-1, min(1, r)) * 32767))
    return bytes(frames), total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bpm", type=float, required=True)
    ap.add_argument("--bars", type=int, default=16)
    ap.add_argument("--style", choices=sorted(STYLES), default="fast")
    ap.add_argument("--out", required=True, help="WAV 输出路径")
    ap.add_argument("--m4a", help="同时转成 m4a（需 macOS afconvert）")
    args = ap.parse_args()

    frames, total = render(args.bpm, args.bars, args.style)
    with wave.open(args.out, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    print("written %s  %.2fs  %.1f BPM  %s" % (args.out, total, args.bpm, args.style))

    if args.m4a:
        if not shutil.which("afconvert"):
            raise SystemExit("afconvert 不可用，无法生成 %s" % args.m4a)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "192000",
                        args.out, args.m4a], check=True)
        print("written %s  %.1f KB" % (args.m4a, os.path.getsize(args.m4a) / 1024.0))


if __name__ == "__main__":
    main()
