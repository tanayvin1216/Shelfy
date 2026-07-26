"""Assertions for RecallSweep (§6).

    ./.venv/bin/jac test tests/sweep_demo.jac

Annex of `sweep_demo.jac` - it sees that module's imports without re-importing.
Each `test` gets its own isolated root, so `run_sweep` rebuilds the demo graph
from scratch inside every one of them.

The load-bearing assertions are the §4 ones. If someone "simplifies" the
matcher back to brand-only, the WEAK/CONFIRMED split collapses and these fail
loudly instead of silently condemning every jar on the shelf.
"""

# --- the money shot ---------------------------------------------------------

test "the backward sweep names both households that took the recalled item home" {
    out = run_sweep(False);
    codes = [n.pickup_code for n in out.notify_households if n.confidence == CONFIRMED];
    assert "4471" in codes, f"4471 missing from {codes}";
    assert "8830" in codes, f"8830 missing from {codes}";
    assert len(codes) == 2, f"expected exactly two confirmed notices, got {codes}";
}

test "every household hop in the trace is marked backward" {
    out = run_sweep(False);
    hops = [h for h in out.trace if h.kind == "Household"];
    assert len(hops) == 3, f"expected 3 household hops, got {len(hops)}";
    for hop in hops {
        assert hop.direction == "backward", f"{hop.label} arrived {hop.direction}";
    }
}

test "the feed reaches the pantry by walking backward, not by a stored pointer" {
    out = run_sweep(False);
    pantry = [h for h in out.trace if h.kind == "Pantry"];
    assert len(pantry) == 1;
    assert pantry[0].direction == "backward";
}

# --- §4 confidence tiers ----------------------------------------------------

test "matching lot code produces CONFIRMED and cites the recall number" {
    out = run_sweep(False);
    hits = [f for f in out.pull_from_shelf if f.confidence == CONFIRMED];
    assert len(hits) == 1, f"expected 1 CONFIRMED, got {len(hits)}";
    assert hits[0].lot_code == "260562";
    assert hits[0].recall_number == "H-1125-2026";
    assert hits[0].classification == "Class I";
    assert "260562" in hits[0].recall_code_info;
}

test "unreadable lot code produces POSSIBLE and surfaces the recall codes" {
    out = run_sweep(False);
    hits = [f for f in out.pull_from_shelf if f.confidence == POSSIBLE];
    assert len(hits) == 1, f"expected 1 POSSIBLE, got {len(hits)}";
    assert hits[0].lot_code == "";
    assert "260562" in hits[0].recall_code_info, "a human cannot compare codes we did not show them";
}

test "a legible non-recalled lot stays WEAK and stays on the shelf" {
    out = run_sweep(False);
    assert len(out.informational) == 1, f"expected 1 WEAK, got {len(out.informational)}";
    weak_hit = out.informational[0];
    assert weak_hit.confidence == WEAK;
    assert weak_hit.lot_code == "991234";
    assert weak_hit.verdict == "keep", "a brand match must not pull an item off the shelf";
    assert weak_hit.on_shelf;
}

test "no household is notified on a WEAK flag" {
    out = run_sweep(False);
    for notice in out.notify_households {
        assert notice.confidence != WEAK, f"{notice.pickup_code} alarmed over a brand match";
    }
}

test "nothing is ever routed to discard by a recall match" {
    out = run_sweep(False);
    for flagged in (out.pull_from_shelf + out.informational) {
        assert flagged.verdict != "discard", f"{flagged.item_id} was discarded on a recall";
    }
}

test "an unrelated item on the same shelf is not flagged" {
    out = run_sweep(False);
    assert out.items_scanned == 4;
    assert out.items_flagged == 3, "the can of green beans should not match a raisin recall";
    brands = [f.brand for f in (out.pull_from_shelf + out.informational)];
    assert "DEL MONTE" not in brands;
}

# --- ingestion, privacy, idempotency ---------------------------------------

test "only Ongoing recalls are ingested" {
    out = run_sweep(False);
    assert out.records_seen == 100, f"expected 100 ongoing records, got {out.records_seen}";
    assert out.records_new + out.records_updated == out.records_seen;
}

test "re-running updates records and edges in place instead of stacking them" {
    _first = run_sweep(False);
    second = run_sweep(False);
    assert second.records_new == 0, f"{second.records_new} recall records duplicated";
    assert second.flags_created == 0, f"{second.flags_created} FlaggedBy edges duplicated";
    assert second.flags_existing == 3;
    assert len(second.notify_households) == 3, "a re-sweep must still name the households";
}

test "the household notice cites the recall and carries no PII" {
    out = run_sweep(False);
    notice = [n for n in out.notify_households if n.pickup_code == "4471"][0];
    assert "H-1125-2026" in notice.message;
    assert "Undeclared peanuts." in notice.message;
    assert notice.preferred_language == "en";
    # Day precision, not second precision — an exact pickup time plus the item and
    # code re-identifies a household to anyone who watched the pickup line (§4).
    assert notice.picked_up_at == "2026-07-18";
}

test "a dead network falls back to the committed snapshot" {
    # 1ms budget against a real HTTP call = a guaranteed timeout, so this
    # exercises the §8 fallback for real instead of mocking it away.
    stranded = run_sweep(True, 0.001);
    assert stranded.source == "cached-snapshot", f"got source {stranded.source}";
    assert "fell back" in stranded.source_note, stranded.source_note;
    assert stranded.records_seen == 100;
    assert len(stranded.notify_households) == 3, "a dead network must not silence the sweep";
}
