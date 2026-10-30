#!/usr/bin/env python3
"""Click Assist episode corpus + offline metrics.

MEASURED vs ADJUDICATED are kept strictly apart:
  * MEASURED   - decisions, reasons, verdicts, latency, activation outcome (from log)
  * ADJUDICATED- intended target, harmfulness (human labels only; "unknown" otherwise)
Renderer agreement is not intent, so intent is never inferred.

Privacy: labels are redacted (hash + length); frames/roles/reasons are kept.

Usage: python3 extract.py [--log PATH] [--out DIR]
"""

import argparse
import hashlib
import json
import os
import re
import statistics
from collections import Counter
from datetime import datetime

AGENT_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}(?:\.\d+)?) \[ClickAssist\] (.*)$")
SERVICE_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})Z \[ClickAssist\] (.*)$")
KV = re.compile(r"(\w+)=(\"[^\"]*\"|\([^)]*\)|[^\s]+)")


def parse_kv(text):
    out = {}
    for k, v in KV.findall(text):
        if v.startswith('"') and v.endswith('"'):
            v = v[1:-1]
        out[k] = v
    return out


def redact(label):
    if not label:
        return label
    return "<redacted:%s:len%d>" % (hashlib.sha256(label.encode()).hexdigest()[:8], len(label))


def parse_log(path):
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = AGENT_LINE.match(line.rstrip("\n")) or SERVICE_LINE.match(line.rstrip("\n"))
            if not m:
                continue
            day, clock, body = m.group(1), m.group(2), m.group(3)
            try:
                ts = datetime.strptime(day + " " + clock, "%Y-%m-%d %H:%M:%S.%f")
            except ValueError:
                try:
                    ts = datetime.strptime(day + " " + clock, "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    continue
            fields = parse_kv(body)
            if "label" in fields:
                fields["label"] = redact(fields["label"])
            yield ts, {"kind": body.split(" ", 1)[0], **fields}


def build_episodes(events):
    episodes, open_ep = [], None
    last_publish, last_overlay = None, None
    for ts, ev in events:
        k = ev["kind"]
        if k == "RESOLVER_PUBLISH":
            last_publish = ev
            continue
        if k == "OVERLAY_STATE":
            last_overlay = (ts, ev)
            continue
        mtype = ev.get("type")
        if mtype and mtype.endswith("MouseDown"):
            if open_ep:
                open_ep["outcome"] = "truncated"
                episodes.append(open_ep)
            open_ep = {
                "started": ts.isoformat(), "gesture": mtype,
                "decision": k, "reason": ev.get("reason"),
                "target": ev.get("target") or ev.get("element"),
                "pointer": ev.get("orig") or ev.get("loc"),
                "mutated": ev.get("mutated"),
                "app": last_publish.get("app") if last_publish else None,
                "pid": last_publish.get("pid") if last_publish else None,
                "tolerance": ev.get("tol") or (last_overlay[1].get("tol") if last_overlay else None),
                "evidence_age_ms": ev.get("age_ms"), "verdict": ev.get("legitimacy"),
                "ring": None, "activation": None, "ended": None,
                "intended_target": "unknown", "harmful": "unknown", "ambiguous": "unknown",
            }
            if last_overlay and (ts - last_overlay[0]).total_seconds() <= 0.6:
                ots, oev = last_overlay
                open_ep["ring"] = {f: oev.get(f) for f in ("action", "target", "frame", "reason", "tier")}
                open_ep["ring"]["age_s"] = round((ts - ots).total_seconds(), 3)
            continue
        if k.startswith("AXPRESS"):
            if open_ep is not None:
                open_ep["activation"] = {f: ev.get(f) for f in ("reason", "success", "target", "request")}
                open_ep["activation"]["status"] = k
            continue
        if mtype and mtype.endswith("MouseUp"):
            if open_ep is not None:
                open_ep["ended"] = ts.isoformat()
                open_ep["outcome"] = "activation" if open_ep["activation"] else "native"
                episodes.append(open_ep)
                open_ep = None
    if open_ep:
        open_ep["outcome"] = "truncated"
        episodes.append(open_ep)
    return episodes


def build_ring_episodes(events):
    """Ring decisions are episodes in their own right: every OVERLAY_STATE line is
    one indication decision (show/none) with its reason, target and evidence age.
    Grouped by pointer position so a hover that redraws 10x counts once."""
    rings, current = [], None
    last_publish = None
    for ts, ev in events:
        if ev["kind"] == "RESOLVER_PUBLISH":
            last_publish = ev
            continue
        if ev["kind"] != "OVERLAY_STATE":
            continue
        ptr = ev.get("pointer")
        same = current is not None and current["pointer"] == ptr and (ts - current["_ts"]).total_seconds() < 0.5
        if same:
            continue
        if current:
            rings.append(current)
        current = {
            "_ts": ts,
            "started": ts.isoformat(),
            "pointer": ptr,
            "action": ev.get("action"),
            "target": ev.get("target"),
            "frame": ev.get("frame"),
            "reason": ev.get("reason"),
            "mode": ev.get("mode"),
            "tier": ev.get("tier"),
            "named": ev.get("named"),
            "weak": ev.get("weak"),
            "legitimacy": ev.get("legitimacy"),
            "app": last_publish.get("app") if last_publish else None,
            "adjudicated_intended": "unknown",
        }
    if current:
        rings.append(current)
    for r in rings:
        r.pop("_ts", None)
    return rings


def ring_metrics(rings):
    shows = [r for r in rings if r["action"] == "show"]
    return {
        "ring_episodes": len(rings),
        "shown": len(shows),
        "hidden": len(rings) - len(shows),
        "shown_rate": round(len(shows) / len(rings), 4) if rings else None,
        "hidden_by_reason": dict(Counter(r["reason"] for r in rings if r["action"] != "show").most_common(12)),
        "shown_by_mode": dict(Counter(r["mode"] for r in shows).most_common(8)),
        "shown_weak": sum(1 for r in shows if r["weak"] == "1"),
        "shown_named": sum(1 for r in shows if r["named"] == "1"),
        "shown_by_app": dict(Counter(r["app"] for r in shows).most_common(10)),
        "shown_weak_rate": round(sum(1 for r in shows if r["weak"] == "1") / len(shows), 4) if shows else None,
        "weak_by_mode": dict(Counter("%s:%s" % (r["mode"], "weak" if r["weak"] == "1" else "strong")
                                     for r in shows).most_common(8)),
        "adjudicated_intended_known": sum(1 for r in rings if r["adjudicated_intended"] != "unknown"),
    }


def metrics(episodes):
    total = len(episodes)
    assisted = [e for e in episodes if e["decision"] == "MUTATE"]
    native = [e for e in episodes if e["decision"] != "MUTATE"]
    acts = Counter((e["activation"] or {}).get("status", "none") for e in assisted)
    ages = []
    for e in episodes:
        try:
            ages.append(float(e["evidence_age_ms"]))
        except (TypeError, ValueError):
            pass
    ages.sort()
    def pct(p):
        if not ages:
            return None
        idx = max(0, min(len(ages) - 1, int(round(p / 100.0 * len(ages))) - 1))
        return round(ages[idx], 1)
    labelled = [e for e in episodes if e["harmful"] != "unknown"]
    harmful = [e for e in labelled if e["harmful"] is True]
    return {
        "episodes": total,
        "assisted": len(assisted),
        "native": len(native),
        "redirect_rate": round(len(assisted) / total, 4) if total else None,
        "native_by_reason": dict(Counter(e["reason"] for e in native).most_common()),
        "activation_status": dict(acts),
        "ring": dict(Counter((e["ring"] or {}).get("action", "no-overlay") for e in episodes)),
        "evidence_age_ms": {"n": len(ages), "p50": pct(50), "p95": pct(95),
                            "max": round(ages[-1], 1) if ages else None},
        "by_app": dict(Counter(e["app"] for e in episodes).most_common(10)),
        "labelled": len(labelled),
        "harmful": len(harmful),
        "harmful_per_1000": round(len(harmful) * 1000.0 / len(labelled), 2) if labelled else None,
        "adjudicated": {
            "intended_target_known": sum(1 for e in episodes if e["intended_target"] != "unknown"),
            "harmful_known": sum(1 for e in episodes if e["harmful"] != "unknown"),
            "note": "intent/harm need human labels; unknown is reported, never inferred",
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default=os.path.expanduser("~/Library/Logs/Mousecape/ClickAssistAgent.log"))
    ap.add_argument("--labels", default=None,
                    help="JSONL of human adjudications keyed by episode 'started'")
    ap.add_argument("--emit-fixtures", default=None,
                    help="write replay fixtures (redacted) to this path")
    ap.add_argument("--include-rotated", action="store_true",
                    help="also read ClickAssistAgent.N.log (older sessions)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    logs = [args.log]
    if args.include_rotated:
        base_dir = os.path.dirname(args.log)
        def rot_index(name):
            parts = name.split(".")
            return int(parts[1]) if len(parts) > 2 and parts[1].isdigit() else 0
        rot = sorted((f for f in os.listdir(base_dir)
                      if f.startswith("ClickAssistAgent.") and f.endswith(".log")),
                     key=rot_index)
        logs = [os.path.join(base_dir, f) for f in rot] + logs
    events = []
    for path in logs:
        if os.path.exists(path):
            events.extend(parse_log(path))
    events.sort(key=lambda e: e[0])
    episodes = build_episodes(events)
    corpus = os.path.join(args.out, "episodes.jsonl")
    with open(corpus, "w") as fh:
        for e in episodes:
            fh.write(json.dumps(e, default=str) + "\n")
    rings = build_ring_episodes(events)
    with open(os.path.join(args.out, "ring_episodes.jsonl"), "w") as fh:
        for r in rings:
            fh.write(json.dumps(r, default=str) + "\n")
    if args.labels and os.path.exists(args.labels):
        labels = {}
        with open(args.labels) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                labels[row["started"]] = row
        for e in episodes:
            row = labels.get(e["started"])
            if row:
                for f in ("intended_target", "harmful", "ambiguous"):
                    if f in row:
                        e[f] = row[f]
        print("labels merged: %d" % sum(1 for e in episodes if e["started"] in labels))

    report = metrics(episodes)
    report["ring_episodes"] = ring_metrics(rings)
    if args.emit_fixtures:
        fx_dir = os.path.dirname(args.emit_fixtures)
        if fx_dir:
            os.makedirs(fx_dir, exist_ok=True)
        with open(args.emit_fixtures, "w") as fh:
            for r in rings:
                if r["action"] != "show" or not r["frame"] or not r["pointer"]:
                    continue
                fh.write(json.dumps({"frame": r["frame"], "pointer": r["pointer"],
                                     "mode": r["mode"], "reason": r["reason"],
                                     "weak": r["weak"]}, default=str) + "\n")
        print("fixtures: %s" % args.emit_fixtures)
    report["source_log"] = args.log
    report["events_parsed"] = len(events)
    with open(os.path.join(args.out, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2, default=str)
    print(json.dumps(report, indent=2, default=str))
    print("\ncorpus: %s (%d episodes)" % (corpus, len(episodes)))


if __name__ == "__main__":
    main()
