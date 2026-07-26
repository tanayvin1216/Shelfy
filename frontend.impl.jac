"""Handlers for the Backshelf console.

Each one is a walker spawn and an assignment. There is no request building, no
URL, no JSON: `root spawn MatchNeeds(...)` is the API call, and `.reports[0]`
comes back as the typed `MatchReport` the server declared.

Every handler reads the walker's result into a LOCAL before writing state. `has`
fields compile to `useState`, so a field assigned earlier in the same handler
is still the old value further down - reading `demo.confirmed_item_id` right
after `demo = ...` throws on null.
"""

impl app.runSeed -> None {
    busy = True;
    status = "SeedPantry -> SeedDemo ...";
    skeleton = (root spawn SeedPantry()).reports[0];
    history = (root spawn SeedDemo()).reports[0];
    seeded = skeleton;
    demo = history;
    confirmedItemId = history.confirmed_item_id;
    status = "Graph ready. "
        + str(skeleton.nodes_created + history.created) + " nodes created, "
        + str(len(history.handouts)) + " handouts on record.";
    busy = False;
}

impl app.runScan -> None {
    busy = True;
    status = "IntakeScan ...";
    res = (root spawn IntakeScan(
        photo_base64=(photo64 if photo64 != "" else BLANK_PNG),
        hint=hint
    )).reports[0];
    intake = res;
    lastItemId = res.item.id;
    cleared = None;
    status = "Scanned. Verdict: " + res.verdict + " on the " + res.holding_shelf + ".";
    busy = False;
}

impl app.runClearLast -> None {
    if lastItemId == "" {
        status = "Nothing scanned yet - run INTAKE SCAN first.";
        return;
    }
    busy = True;
    status = "ClearItem on the item just scanned ...";
    res = (root spawn ClearItem(item_id=lastItemId)).reports[0];
    cleared = res;
    status = "Refused." if res.refused else "Cleared onto " + res.shelf + ".";
    busy = False;
}

impl app.runClearConfirmed -> None {
    if confirmedItemId == "" {
        status = "Run SEED PANTRY + DEMO first, then RECALL SWEEP.";
        return;
    }
    busy = True;
    status = "ClearItem on the recalled item ...";
    res = (root spawn ClearItem(item_id=confirmedItemId)).reports[0];
    cleared = res;
    status = "Refused - the gate held." if res.refused
        else "Cleared. No confirmed flag on it yet - run RECALL SWEEP first.";
    busy = False;
}

impl app.runSearch -> None {
    busy = True;
    status = "MatchNeeds ...";
    res = (root spawn MatchNeeds(
        pickup_code=pickup,
        constraints_text=constraints,
        language=language
    )).reports[0];
    matched = res;
    status = str(len(res.offered)) + " offered, " + str(len(res.withheld)) + " withheld.";
    busy = False;
}

impl app.runSweep -> None {
    busy = True;
    status = "RecallSweep - syncing recalls, then walking the graph ...";
    res = (root spawn RecallSweep(live=useLiveFeed, limit=100)).reports[0];
    swept = res;
    status = str(len(res.pull_from_shelf)) + " to pull, "
        + str(len(res.notify_households)) + " households to notify.";
    busy = False;
}

impl app.toggleFeed(e: MouseEvent) -> None {
    useLiveFeed = not useLiveFeed;
}

"""Read the chosen photo as base64 so IntakeScan gets the real label.

FileReader hands back a `data:image/...;base64,` URL; `image_from_base64` on
the server strips that prefix, so it is passed through whole.
"""
impl app.onPhoto(e: ChangeEvent) -> None {
    picker: any = e.target;
    files: any = picker.files;
    if not files or len(files) == 0 {  # jac:ignore[E1053]
        photo64 = "";
        photoName = "";
        return;
    }
    picked: any = files[0];
    photoName = str(picked.name);

    # Browser globals have no typed stubs, so the whole FileReader dance goes
    # through `any` - the same escape hatch llm.sv.jac uses for byllm's Image.
    assign: any = lambda(payload: any) {
        photo64 = str(payload);
    };
    reader: any = new(_browser.FileReader);  # jac:ignore[E1053]
    reader.onload = lambda(ev: any) {
        assign.call(None, ev.target.result);
    };
    reader.readAsDataURL(picked);
}
