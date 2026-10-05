#!/usr/bin/env python3
"""Compare two short.sh JSON snapshots (e.g. stock vs clover) for A/B reporting.

    python3 tools/measure/compare.py stock.json clover.json
"""
import json
import sys


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    k = (len(s) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)


def launch(d):
    by = {}
    for x in d.get("app_launch_ms", []):
        by.setdefault(x["app"], []).append(x["total_ms"])
    return by


def freq_share(d):
    out = {}
    for p in d.get("cpufreq", []):
        tot = sum(p["time_in_state"].values()) or 1
        out[p["policy"]] = {
            "governor": p["governor"],
            "min_khz": p["min_khz"],
            "max_khz": p["max_khz"],
            "share": {int(k): round(100.0 * v / tot, 2)
                      for k, v in sorted(p["time_in_state"].items(), key=lambda kv: int(kv[0]))},
        }
    return out


def idle_share(d):
    st = d.get("cpuidle", [])
    tot = sum(s["time_us"] for s in st) or 1
    return {s["name"]: round(100.0 * s["time_us"] / tot, 2) for s in st}


def main(pa, pb):
    A, B = json.load(open(pa)), json.load(open(pb))
    print("A: %s | %s" % (A.get("label"), A.get("build", "")[:70]))
    print("B: %s | %s" % (B.get("label"), B.get("build", "")[:70]))
    print("models: %s / %s" % (A.get("model"), B.get("model")))

    print("\n== app launch (ms) ==")
    la, lb = launch(A), launch(B)
    for app in sorted(set(la) | set(lb)):
        for nm, v in (("A", la.get(app, [])), ("B", lb.get(app, []))):
            if v:
                print("  %s %-40s n=%d min=%s P50=%.0f P95=%.0f max=%s" %
                      (nm, app, len(v), min(v), pct(v, 50) or 0, pct(v, 95) or 0, max(v)))
        if la.get(app) and lb.get(app):
            d50 = (pct(lb[app], 50) or 0) - (pct(la[app], 50) or 0)
            d95 = (pct(lb[app], 95) or 0) - (pct(la[app], 95) or 0)
            print("     delta B-A: P50 %+.0f ms, P95 %+.0f ms" % (d50, d95))

    print("\n== frame stats (dumpsys gfxinfo) ==")
    for nm, d in (("A", A), ("B", B)):
        for g in d.get("gfxinfo", []):
            print("  %s %-30s frames=%s janky=%s p50=%s p90=%s p95=%s p99=%s" %
                  (nm, g.get("app"), g.get("total_frames"), g.get("janky_frames"),
                   g.get("p50_ms"), g.get("p90_ms"), g.get("p95_ms"), g.get("p99_ms")))

    print("\n== cpufreq residency share (%%) ==")
    fa, fb = freq_share(A), freq_share(B)
    for pol in sorted(set(fa) | set(fb)):
        print("  %s" % pol)
        for nm, f in (("A", fa.get(pol)), ("B", fb.get(pol))):
            if f:
                print("    %s gov=%s %s-%s %s" %
                      (nm, f["governor"], f["min_khz"], f["max_khz"],
                       " ".join("%d:%.1f%%" % (k, v) for k, v in f["share"].items())))

    print("\n== cpuidle residency share (%%) ==")
    print("  A: %s" % idle_share(A))
    print("  B: %s" % idle_share(B))

    print("\n== hottest thermal zones (milli-C) ==")
    for nm, d in (("A", A), ("B", B)):
        z = sorted((t for t in d.get("thermal", []) if t.get("temp_milli")),
                   key=lambda t: -t["temp_milli"])[:6]
        print("  %s: %s" % (nm, ", ".join("%s=%s" % (t["type"], t["temp_milli"]) for t in z)))
    cool = {c["type"]: c for c in A.get("cooling", [])}
    coolb = {c["type"]: c for c in B.get("cooling", [])}
    if cool or coolb:
        print("  cooling A: %s" % {k: v["cur_state"] for k, v in sorted(cool.items())})
        print("  cooling B: %s" % {k: v["cur_state"] for k, v in sorted(coolb.items())})

    print("\n== gpu ==")
    print("  A: %s" % A.get("gpu"))
    print("  B: %s" % B.get("gpu"))

    print("\n== memory ==")
    for k in ("MemTotal", "MemFree", "MemAvailable", "Cached", "SwapTotal", "SwapFree",
              "zram_disksize", "zram_comp", "mglru", "psi_present", "workqueue_cpumask"):
        print("  %-18s A=%-14s B=%s" % (k, A.get("memory", {}).get(k), B.get("memory", {}).get(k)))

    print("\n== suspend ==")
    print("  A: debugfs=%s stats=%s" % (A.get("suspend", {}).get("debugfs"), A.get("suspend", {}).get("stats")))
    print("  B: debugfs=%s stats=%s" % (B.get("suspend", {}).get("debugfs"), B.get("suspend", {}).get("stats")))
    for nm, d in (("A", A), ("B", B)):
        ws = d.get("suspend", {}).get("wakeup_sources", [])[:6]
        if ws:
            print("  %s top wakeup sources: %s" % (nm, ", ".join("%s=%sms" % (w["name"], w["total_time_ms"]) for w in ws)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])