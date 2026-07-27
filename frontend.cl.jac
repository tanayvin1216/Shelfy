"""Backshelf - the volunteer console.

Every button on this page is one walker spawn. There is no REST client, no
fetch wrapper and no serialisation code: `root spawn RecallSweep(live=...)`
crosses the wire and comes back as a typed `SweepReport`, so `row.pickup_code`
below is a real field on a real object, checked at compile time.

Layout is an asymmetric two-column document - a narrow running-order rail and a
wide results column - inside one flex row that wraps to a single column on a
phone. No media query is needed for that and none is available to inline
styles, so the wrap thresholds are the `flex-basis` values on the two children.

Handlers live in `frontend.impl.jac`.
"""

import from .components.Panel {
    Panel, Beat, CodeCompare, Stat, Tag, Field, Choice, Action, SmallButton
}

# Design tokens. A `glob` in a `.cl.jac` is a module-local JS variable and is
# NOT exported, so these are declared here as well as in Panel.cl.jac rather
# than imported - a few duplicated strings beat an abstraction that fails the
# Vite build.
glob PAPER: str = "#f2f0eb";
glob CARD: str = "#fffdf8";
glob RULE: str = "#c9c3b6";
glob INK: str = "#15171c";
glob MUTED: str = "#6d6961";
glob ALARM: str = "#a4231d";
glob HOLD: str = "#8a5d0b";
glob OK: str = "#2c6141";
glob MONO: str = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace";

"""A 1x1 PNG. Under MockLLM the pixels are irrelevant - it is the placeholder
for a scan when the volunteer has not attached a photo yet."""
glob BLANK_PNG: str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

"""The browser global scope, held behind `any` because `jac check` has no typed
stubs for `FileReader` or `Date` and would otherwise fail the whole module."""
glob _browser: any = globalThis;

sv import from graph { SeedPantry, SeedReport }
sv import from demo { SeedDemo, DemoReport }
sv import from intake { IntakeScan, ClearItem, IntakeReport, ClearReport }
sv import from client_search { MatchNeeds, MatchReport }
sv import from sweep { RecallSweep, SweepReport }
sv import from settings { LlmStatus, SetLlmKey, LlmStatusView }

"""The one small-caps monospace marker used for every section label."""
def lbl(color: str, gap: str) -> dict[str, object] {
    return {
        "display": "block",
        "fontFamily": MONO,
        "fontSize": "0.62rem",
        "letterSpacing": "0.18em",
        "textTransform": "uppercase",
        "color": color,
        "marginBottom": gap
    };
}

"""Comma-join a list of strings.

`", ".join(xs)` compiles to a polymorphic dispatch that throws inside the
render on the client, and the error boundary swallows the message - the page
just goes blank. An explicit loop is three lines and cannot fail."""
def commas(parts: list[str]) -> str {
    line: str = "";
    for (i, part) in enumerate(parts) {
        line = line + (", " if i > 0 else "") + part;
    }
    return line;
}

def:pub app -> JsxElement {
    has status: str = "Nothing run yet. Start at 1.",
        busy: bool = False,
        seeded: SeedReport | None = None,
        demo: DemoReport | None = None,
        intake: IntakeReport | None = None,
        cleared: ClearReport | None = None,
        matched: MatchReport | None = None,
        swept: SweepReport | None = None,
        photo64: str = "",
        photoName: str = "",
        scanSecs: str = "",
        hint: str = "dented can from the back of the pallet",
        lastItemId: str = "",
        confirmedItemId: str = "",
        pickup: str = "8830",
        constraints: str = "allergic to peanuts, diabetic",
        language: str = "English",
        useLiveFeed: bool = False,
        apiKey: str = "",
        llmState: LlmStatusView | None = None,
        llmNote: str = "";

    """Ask the server what it is running on before the volunteer touches
    anything - the mock/Gemini banner has to be right on first paint, not after
    the first scan."""
    async can with entry {
        llmState = (root spawn LlmStatus()).reports[0];
    }

    async def runSaveKey -> None;
    async def runClearKey -> None;
    async def runSeed -> None;
    async def runScan -> None;
    async def runClearLast -> None;
    async def runClearConfirmed -> None;
    async def runSearch -> None;
    async def runSweep -> None;
    def toggleFeed(e: MouseEvent) -> None;
    def pickLanguage(choice: str) -> None;
    def onPhoto(e: ChangeEvent) -> None;

    # Unpacked once here rather than null-guarded at six points in the markup.
    # `llmState` is None only for the instant between first paint and the mount
    # effect landing, and "checking" is the honest word for that instant.
    llmLive: bool = llmState is not None and not llmState.using_mock_llm;
    llmShade: str = OK if llmLive else HOLD;
    llmSource: str = llmState.source if llmState is not None else "checking";
    llmMasked: str = llmState.masked_key if llmState is not None else "";
    llmModel: str = llmState.model if llmState is not None else "";
    llmStamp: str = llmState.updated_at if llmState is not None else "";
    llmError: str = llmState.last_error if llmState is not None else "";

    return <div
        style={{
            "minHeight": "100vh",
            "background": PAPER,
            "color": INK,
            "fontFamily": "'Helvetica Neue', Helvetica, Arial, sans-serif",
            "fontSize": "0.92rem",
            "lineHeight": "1.5"
        }}
    >
        <div style={{"maxWidth": "1220px", "margin": "0 auto", "padding": "2rem 1.1rem 5rem"}}>

            <header style={{"borderBottom": "3px solid " + INK, "paddingBottom": "1rem", "marginBottom": "2.25rem"}}>
                <span style={lbl(MUTED, "0.35rem")}>
                    JacHacks SF 2026 / food pantry intake + recall propagation
                </span>
                <h1 style={{"margin": "0", "fontSize": "clamp(2.1rem, 8vw, 3.4rem)", "letterSpacing": "-0.035em", "fontWeight": "700", "lineHeight": "0.95"}}>
                    Backshelf
                </h1>
                <p style={{"margin": "0.55rem 0 0", "maxWidth": "48ch", "fontSize": "1.02rem", "color": "#33302b"}}>
                    A recall announced on Tuesday affects the can that went out the door
                    on Saturday. This is the graph that connects the two.
                </p>
            </header>

            <div style={{"display": "flex", "flexWrap": "wrap", "gap": "2.5rem", "alignItems": "flex-start"}}>

                <aside style={{"flex": "1 1 17rem", "minWidth": "0"}}>
                    <span style={lbl(MUTED, "0.5rem")}>Running order - one walker each</span>

                    <Action step="1" label="seed pantry + handout history" onRun={runSeed} busy={busy}/>
                    <Action step="2" label="intake scan" onRun={runScan} busy={busy}/>
                    <Action step="3" label="clear the scanned item" onRun={runClearLast} busy={busy}/>
                    <Action step="4" label="client shelf search" onRun={runSearch} busy={busy}/>
                    <Action step="5" label="recall sweep" onRun={runSweep} busy={busy} tone="block"/>
                    <Action step="6" label="try to clear a recalled item" onRun={runClearConfirmed} busy={busy} tone="block"/>

                    <div style={{"marginTop": "1.5rem", "paddingTop": "0.9rem", "borderTop": "2px solid " + INK}}>
                        <span style={lbl(MUTED, "0.5rem")}>Inputs</span>

                        <label style={{"display": "block", "marginBottom": "0.8rem"}}>
                            <span style={lbl(MUTED, "0.25rem")}>Label photo - camera or file</span>
                            <input type="file" accept="image/*" capture="environment" onChange={onPhoto}
                                style={{"width": "100%", "boxSizing": "border-box", "fontFamily": MONO, "fontSize": "0.72rem"}}/>
                            <span style={{"fontFamily": MONO, "fontSize": "0.64rem", "color": MUTED}}>
                                {photoName if photoName != "" else "none yet - a blank placeholder is sent"}
                            </span>
                        </label>

                        <Field label="volunteer hint" value={hint} onChange={lambda v: str { hint = v; }}/>
                        <Field label="pickup code" value={pickup} onChange={lambda v: str { pickup = v; }}/>
                        <Field label="constraints - free text" value={constraints} onChange={lambda v: str { constraints = v; }}/>
                        <Choice label="client language" options={["English", "Español", "Tiếng Việt"]}
                                value={language} onPick={pickLanguage}/>

                        <button type="button" onClick={toggleFeed}
                            style={{
                                "width": "100%", "padding": "0.45rem", "borderRadius": "0",
                                "border": "1px solid " + RULE, "background": "transparent",
                                "color": MUTED, "fontFamily": MONO, "fontSize": "0.64rem",
                                "letterSpacing": "0.1em", "textTransform": "uppercase",
                                "cursor": "pointer", "textAlign": "left"
                            }}>
                            {"recall source: live openFDA" if useLiveFeed else "recall source: cached snapshot"}
                        </button>
                    </div>

                    {#*
                       The model switch. A judge or a volunteer can paste a
                       Gemini key here and the very next scan uses it - the key
                       goes onto a node in the graph, not into a file, and the
                       byLLM router re-reads it per call. Blank + SAVE, or
                       CLEAR, puts it straight back on MockLLM.

                       The banner is loud on purpose: under MockLLM every scan
                       returns the same canned can of green beans, and anyone
                       watching a demo deserves to know that from the screen
                       rather than from a footnote.
                    *#}
                    <div style={{"marginTop": "1.5rem", "paddingTop": "0.9rem", "borderTop": "2px solid " + INK}}>
                        <span style={lbl(MUTED, "0.5rem")}>{"byLLM - source: " + llmSource}</span>

                        <div style={{
                            "borderLeft": "6px solid " + llmShade,
                            "borderTop": "1px solid " + RULE,
                            "borderRight": "1px solid " + RULE,
                            "borderBottom": "1px solid " + RULE,
                            "background": CARD,
                            "padding": "0.6rem 0.8rem 0.7rem",
                            "marginBottom": "0.9rem"
                        }}>
                            <span style={lbl(llmShade, "0.15rem")}>every scan is read by</span>
                            <div style={{
                                "fontFamily": MONO,
                                "fontSize": "1.55rem",
                                "lineHeight": "1",
                                "letterSpacing": "0.03em",
                                "fontWeight": "700",
                                "color": llmShade
                            }}>
                                {"GEMINI" if llmLive else "MOCKLLM"}
                            </div>
                            <p style={{"margin": "0.4rem 0 0", "fontSize": "0.82rem", "lineHeight": "1.4"}}>
                                {llmModel + " reads the photo you attach."
                                 if llmLive
                                 else "No key on file, so every photo comes back as the same canned label - DEL MONTE Cut Green Beans. Every other path is real."}
                            </p>
                            {if llmMasked != "" {
                                <p style={{"margin": "0.4rem 0 0", "fontFamily": MONO, "fontSize": "0.66rem", "color": MUTED}}>
                                    {"key on file " + llmMasked + " / saved " + llmStamp}
                                </p>
                            }}
                        </div>

                        <Field label="gemini api key - stored in the graph, never echoed back"
                               value={apiKey} kind="password"
                               placeholder={"AIza..." if llmMasked == "" else "paste a new key to replace " + llmMasked}
                               onChange={lambda v: str { apiKey = v; }}/>

                        <div style={{"display": "flex", "marginBottom": "0.6rem"}}>
                            <SmallButton label="save key" onRun={runSaveKey} primary={True} busy={busy}/>
                            <SmallButton label="clear" onRun={runClearKey} busy={busy}/>
                        </div>

                        {if llmNote != "" {
                            <p style={{"margin": "0", "fontFamily": MONO, "fontSize": "0.66rem", "color": MUTED, "lineHeight": "1.45"}}>
                                {llmNote}
                            </p>
                        }}

                        {if llmError != "" {
                            <p style={{
                                "margin": "0.5rem 0 0",
                                "borderLeft": "3px solid " + ALARM,
                                "paddingLeft": "0.6rem",
                                "fontFamily": MONO,
                                "fontSize": "0.64rem",
                                "color": ALARM,
                                "lineHeight": "1.45",
                                "wordBreak": "break-word"
                            }}>
                                {"last model error - answered from MockLLM instead so nothing broke: " + llmError}
                            </p>
                        }}
                    </div>

                    <p style={{"fontFamily": MONO, "fontSize": "0.68rem", "color": MUTED, "marginTop": "1.3rem", "borderLeft": "3px solid " + RULE, "paddingLeft": "0.65rem", "lineHeight": "1.45"}}>
                        {status}
                    </p>
                </aside>

                <main style={{"flex": "999 1 26rem", "minWidth": "0"}}>

                    {if seeded is None and intake is None and swept is None {
                        <Panel title="Start here" meta="nothing has run yet">
                            <p style={{"margin": "0", "maxWidth": "60ch"}}>
                                Press <strong>1</strong> to build the pantry graph and a Saturday's
                                worth of handout history, then work down the rail. Step 5 is the one
                                no existing pantry system can do.
                            </p>
                        </Panel>
                    }}

                    {if seeded is not None {
                        <Panel title="Graph" meta={"pantry " + seeded.pantry_name}>
                            <p style={{"margin": "0 0 0.4rem"}}>
                                {"nodes created this run: " + str(seeded.nodes_created)
                                 + (" - the seed walkers are idempotent, so a second press changes nothing" if seeded.already_seeded else "")}
                            </p>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0"}}>
                                {"shelves: " + commas(seeded.shelves)}
                            </p>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0.15rem 0 0"}}>
                                {"allergen vocabulary: " + commas(seeded.allergens)}
                            </p>
                            {if demo is not None {
                                <p style={{"margin": "0.7rem 0 0"}}>
                                    {"distribution history: " + str(len(demo.handouts))
                                     + " handouts to pickup codes " + commas(demo.households)
                                     + ". No recall flags exist yet."}
                                </p>
                            }}
                        </Panel>
                    }}

                    {if intake is not None {
                        <Panel title="Intake scan"
                               meta={"byLLM " + ("MockLLM" if intake.using_mock_llm else "Gemini")
                                     + (" / " + scanSecs + "s" if scanSecs != "" else "")}>

                            <div style={{"display": "flex", "flexWrap": "wrap", "gap": "0.6rem 1.5rem", "alignItems": "baseline", "marginBottom": "0.5rem"}}>
                                <h3 style={{"margin": "0", "fontSize": "1.35rem", "letterSpacing": "-0.02em"}}>
                                    {intake.item.brand + " " + intake.item.product}
                                </h3>
                                <span style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED}}>
                                    {intake.item.date_value + " / lot "
                                     + (intake.item.lot_code if intake.item.lot_code != "" else "not legible")}
                                </span>
                            </div>

                            <div style={{"marginBottom": "0.9rem"}}>
                                <Tag text={intake.verdict} tone={"block" if intake.verdict == "discard" else ("hold" if intake.verdict == "review" else "ok")}/>
                                <Tag text={"held on " + intake.holding_shelf}/>
                                <Tag text={"confidence " + str(intake.item.extraction_confidence)}/>
                                {if intake.days_past_code > 0 {
                                    <Tag text={str(intake.days_past_code) + " days past code"} tone="hold"/>
                                }}
                            </div>

                            {if intake.days_past_code > 0 and intake.verdict != "discard" {
                                <Beat tone="hold"
                                      kicker="the mistake this rebuild exists to fix"
                                      headline={str(intake.days_past_code) + " days past the date - and still food."}>
                                    <div style={{"display": "flex", "flexWrap": "wrap", "gap": "0.9rem", "margin": "0 0 0.7rem"}}>
                                        <div style={{"flex": "1 1 12rem", "borderTop": "2px solid " + ALARM, "paddingTop": "0.35rem"}}>
                                            <span style={lbl(ALARM, "0.15rem")}>Shelfy v1 would have said</span>
                                            <div style={{"fontFamily": MONO, "fontSize": "1.25rem", "color": ALARM, "letterSpacing": "0.04em"}}>DISCARD</div>
                                            <p style={{"margin": "0.2rem 0 0", "fontSize": "0.82rem", "color": MUTED}}>
                                                v1 routed anything past its date to the bin.
                                            </p>
                                        </div>
                                        <div style={{"flex": "1 1 12rem", "borderTop": "2px solid " + HOLD, "paddingTop": "0.35rem"}}>
                                            <span style={lbl(HOLD, "0.15rem")}>Backshelf v2 says</span>
                                            <div style={{"fontFamily": MONO, "fontSize": "1.25rem", "color": HOLD, "letterSpacing": "0.04em"}}>REVIEW</div>
                                            <p style={{"margin": "0.2rem 0 0", "fontSize": "0.82rem", "color": MUTED}}>
                                                {"published window for " + intake.item.category + ": "
                                                 + (intake.shelf_life_window if intake.shelf_life_window != "" else "see the food bank guide")}
                                            </p>
                                        </div>
                                    </div>
                                    <p style={{"margin": "0", "maxWidth": "64ch", "fontSize": "0.88rem"}}>
                                        Outside infant formula and baby food, date labels are not federally
                                        regulated and are not safety dates. v1 destroyed edible food at
                                        organisations that never have enough of it.
                                    </p>
                                </Beat>
                            }}

                            {if intake.verdict == "discard" {
                                <Beat tone="block" kicker="section 4 - this category really does discard"
                                      headline="Discard, and not because of the date alone.">
                                    <p style={{"margin": "0", "maxWidth": "64ch"}}>{intake.verdict_reason}</p>
                                </Beat>
                            }}

                            <p style={{"margin": "0 0 0.8rem", "maxWidth": "66ch"}}>{intake.verdict_reason}</p>

                            {if len(intake.recall_matches) > 0 {
                                <div style={{"marginBottom": "1.1rem"}}>
                                    <span style={lbl(INK, "0.35rem")}>Recall comparison - a human reads both codes</span>
                                    {for (i, rm) in enumerate(intake.recall_matches) {
                                        <div key={str(i)}>
                                            <p style={{"margin": "0.6rem 0 0", "fontSize": "0.86rem"}}>
                                                {rm.recall_number + " (" + rm.classification + ") - " + rm.reason}
                                            </p>
                                            <CodeCompare scanned={rm.scanned_lot} recalled={rm.recall_lot_codes}
                                                         confidence={rm.confidence} note={rm.note}/>
                                        </div>
                                    }}
                                </div>
                            }}

                            <span style={lbl(MUTED, "0.3rem")}>
                                {"Reasoning trace - " + str(intake.recall_records_compared) + " active recalls compared"}
                            </span>
                            <div style={{"overflowX": "auto"}}>
                                <table style={{"width": "100%", "borderCollapse": "collapse", "fontFamily": MONO, "fontSize": "0.7rem"}}>
                                    <tbody>
                                        {for (i, step) in enumerate(intake.trace) {
                                            <tr key={str(i)} style={{"borderTop": "1px solid " + RULE}}>
                                                <td style={{"padding": "0.3rem 0.6rem 0.3rem 0", "color": MUTED, "whiteSpace": "nowrap", "verticalAlign": "top"}}>{step.source}</td>
                                                <td style={{"padding": "0.3rem 0.6rem 0.3rem 0", "whiteSpace": "nowrap", "verticalAlign": "top"}}>{step.step}</td>
                                                <td style={{"padding": "0.3rem 0", "verticalAlign": "top"}}>{step.detail}</td>
                                            </tr>
                                        }}
                                    </tbody>
                                </table>
                            </div>
                        </Panel>
                    }}

                    {if cleared is not None {
                        <Panel title="Clearance gate" meta="enforced in the walker, not in this page">
                            {if cleared.refused {
                                <div style={{"border": "3px solid " + ALARM, "background": CARD, "padding": "1rem 1.1rem", "marginBottom": "0.9rem"}}>
                                    <span style={lbl(ALARM, "0.2rem")}>ClearItem returned</span>
                                    <div style={{"fontFamily": MONO, "fontSize": "clamp(2.2rem, 9vw, 3.6rem)", "lineHeight": "1", "letterSpacing": "0.02em", "color": ALARM, "fontWeight": "700"}}>
                                        REFUSED
                                    </div>
                                    <div style={{"margin": "0.6rem 0 0.5rem"}}>
                                        {for (i, rn) in enumerate(cleared.blocking_recalls) {
                                            <Tag key={str(i)} text={rn} tone="block"/>
                                        }}
                                    </div>
                                    <p style={{"margin": "0", "maxWidth": "68ch"}}>{cleared.refusal_reason}</p>
                                    <p style={{"margin": "0.7rem 0 0", "fontSize": "0.82rem", "color": MUTED, "maxWidth": "62ch"}}>
                                        This check lives inside the ClearItem walker, so it holds for the
                                        button above, for curl, and for anything else that ever calls
                                        POST /walker/ClearItem.
                                    </p>
                                </div>
                            } else {
                                <div style={{"borderLeft": "6px solid " + OK, "border": "1px solid " + RULE, "background": CARD, "padding": "0.8rem 1rem"}}>
                                    <span style={lbl(OK, "0.2rem")}>ClearItem returned</span>
                                    <div style={{"fontFamily": MONO, "fontSize": "1.5rem", "color": OK, "letterSpacing": "0.04em"}}>
                                        {"CLEARED onto " + cleared.shelf}
                                    </div>
                                    <p style={{"margin": "0.35rem 0 0"}}>
                                        Human clearance recorded. No item reaches a shelf without it.
                                    </p>
                                </div>
                            }}
                        </Panel>
                    }}

                    {if matched is not None {
                        <Panel title="Client shelf search"
                               meta={"pickup " + (matched.pickup_code if matched.household_found else "anonymous") + " / " + matched.language}>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0 0 1rem", "lineHeight": "1.5"}}>
                                {"free text \"" + constraints + "\" resolved to: "
                                 + (commas(matched.avoiding) if len(matched.avoiding) > 0 else "nothing")}
                                <br/>
                                {str(matched.items_considered) + " items considered across "
                                 + commas(matched.shelves_searched) + " / answering in " + matched.language}
                            </p>

                            {if len(matched.offered) == 0 {
                                <p style={{"margin": "0 0 1rem"}}>
                                    Nothing on the shelf clears every constraint right now.
                                </p>
                            }}
                            {for (i, m) in enumerate(matched.offered) {
                                <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.75rem 0"}}>
                                    <strong style={{"fontSize": "1.02rem"}}>{m.item.brand + " " + m.item.product}</strong>
                                    <span style={{"fontFamily": MONO, "fontSize": "0.68rem", "color": MUTED, "marginLeft": "0.6rem"}}>
                                        {m.matched_shelf}
                                    </span>
                                    <p style={{"margin": "0.3rem 0 0", "maxWidth": "68ch"}}>{m.explanation}</p>
                                </div>
                            }}

                            {if len(matched.withheld) > 0 {
                                <div style={{"marginTop": "1.3rem"}}>
                                    <span style={lbl(MUTED, "0.35rem")}>Withheld, and why - the prune is never silent</span>
                                    {for (i, w) in enumerate(matched.withheld) {
                                        <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.45rem 0", "fontSize": "0.85rem"}}>
                                            <Tag text={w.reason} tone="hold"/>
                                            {w.brand + " " + w.product + " - " + w.detail}
                                        </div>
                                    }}
                                </div>
                            }}

                            <p style={{"marginTop": "1.1rem", "fontSize": "0.82rem", "color": MUTED, "maxWidth": "68ch", "borderLeft": "3px solid " + RULE, "paddingLeft": "0.65rem"}}>
                                {matched.framing_note}
                            </p>
                        </Panel>
                    }}

                    {if swept is not None {
                        <Panel title="Recall sweep"
                               meta={swept.source + " / " + str(swept.records_seen) + " ongoing recalls / " + swept.synced_at}>

                            <div style={{"display": "flex", "flexWrap": "wrap", "gap": "0.9rem", "marginBottom": "1.5rem"}}>
                                <Stat value={str(swept.items_scanned)} label="items scanned"/>
                                <Stat value={str(swept.confirmed)} label="confirmed" tone="block"/>
                                <Stat value={str(swept.possible)} label="possible" tone="hold"/>
                                <Stat value={str(swept.weak)} label="brand only"/>
                                <Stat value={str(len(swept.notify_households))} label="households" tone="block"/>
                            </div>

                            {#* The money shot. Largest type on the page, first thing in the panel. *#}
                            <div style={{"borderTop": "3px solid " + ALARM, "borderBottom": "1px solid " + RULE, "padding": "0.7rem 0 1rem", "marginBottom": "1.8rem"}}>
                                <span style={lbl(ALARM, "0.15rem")}>
                                    Households that already took this home
                                </span>
                                <p style={{"margin": "0 0 1rem", "maxWidth": "56ch", "fontSize": "1.02rem"}}>
                                    Reached by walking the <span style={{"fontFamily": MONO}}>Received</span> edge
                                    <strong> backwards</strong>, from the recalled Item to the people holding it.
                                </p>

                                {if len(swept.notify_households) == 0 {
                                    <p style={{"margin": "0", "color": MUTED}}>
                                        Nothing distributed matches an active recall. Press 1 first if the
                                        graph is empty.
                                    </p>
                                }}
                                {for (i, h) in enumerate(swept.notify_households) {
                                    <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.85rem 0 0.7rem", "display": "flex", "flexWrap": "wrap", "gap": "0.4rem 1.4rem", "alignItems": "baseline"}}>
                                        <div style={{"flex": "0 0 auto"}}>
                                            <span style={lbl(MUTED, "0.1rem")}>pickup code</span>
                                            <div style={{"fontFamily": MONO, "fontSize": "clamp(2.4rem, 11vw, 3.6rem)", "lineHeight": "0.95", "letterSpacing": "0.06em", "fontWeight": "700"}}>
                                                {h.pickup_code}
                                            </div>
                                        </div>
                                        <div style={{"flex": "1 1 18rem", "minWidth": "0"}}>
                                            <div style={{"marginBottom": "0.3rem"}}>
                                                <Tag text={h.confidence} tone={"block" if h.confidence == "CONFIRMED" else "hold"}/>
                                                <Tag text={h.classification} tone="block"/>
                                                <Tag text={"lang " + h.preferred_language}/>
                                                <Tag text={"reachable" if h.contact_on_file else "no contact on file"}
                                                     tone={"ok" if h.contact_on_file else "neutral"}/>
                                                <Tag text={"picked up " + h.picked_up_at}/>
                                            </div>
                                            <p style={{"margin": "0", "maxWidth": "70ch"}}>{h.message}</p>
                                        </div>
                                    </div>
                                }}

                                <p style={{"margin": "1rem 0 0", "fontSize": "0.84rem", "color": MUTED, "maxWidth": "62ch", "borderLeft": "3px solid " + RULE, "paddingLeft": "0.65rem"}}>
                                    A pickup code is the entire identity of a household here. No name, no
                                    address, no phone number and no pickup time is stored in the graph or
                                    published in this report.
                                </p>
                            </div>

                            <span style={lbl(INK, "0.5rem")}>Pull from the shelf now</span>
                            {if len(swept.pull_from_shelf) == 0 {
                                <p style={{"margin": "0 0 1.5rem", "color": MUTED}}>Nothing on the shelf matched.</p>
                            }}
                            {for (i, row) in enumerate(swept.pull_from_shelf) {
                                <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.7rem 0 0.9rem"}}>
                                    <Tag text={row.confidence} tone={"block" if row.confidence == "CONFIRMED" else "hold"}/>
                                    <strong style={{"fontSize": "1.02rem"}}>{row.brand + " " + row.product}</strong>
                                    <p style={{"margin": "0.3rem 0 0", "maxWidth": "70ch", "fontSize": "0.88rem"}}>
                                        {row.recall_number + " (" + row.classification + ") - " + row.recall_reason}
                                    </p>
                                    <CodeCompare scanned={row.lot_code} recalled={row.recall_code_info}
                                                 confidence={row.confidence} note={row.matched_fields}/>
                                    <p style={{"margin": "0.45rem 0 0", "fontFamily": MONO, "fontSize": "0.7rem", "color": ALARM if row.confidence == "CONFIRMED" else HOLD}}>
                                        {row.action}
                                    </p>
                                </div>
                            }}

                            {if len(swept.informational) > 0 {
                                <div style={{"marginTop": "1.8rem"}}>
                                    <span style={lbl(INK, "0.3rem")}>Brand match only - these stay on the shelf</span>
                                    <p style={{"margin": "0 0 0.5rem", "maxWidth": "64ch", "fontSize": "0.88rem"}}>
                                        Recalls are lot-specific. v1 matched on brand alone and would have
                                        pulled every one of these. Section 4 forbids it: the codes go
                                        side by side and a human decides.
                                    </p>
                                    {for (i, row) in enumerate(swept.informational) {
                                        <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.7rem 0 0.9rem"}}>
                                            <Tag text={row.confidence}/>
                                            <strong style={{"fontSize": "1.02rem"}}>{row.brand + " " + row.product}</strong>
                                            <p style={{"margin": "0.3rem 0 0", "maxWidth": "70ch", "fontSize": "0.88rem"}}>
                                                {row.recall_number + " (" + row.classification + ") - " + row.recall_reason}
                                            </p>
                                            <CodeCompare scanned={row.lot_code} recalled={row.recall_code_info}
                                                         confidence={row.confidence} note={row.matched_fields}/>
                                            <p style={{"margin": "0.45rem 0 0", "fontFamily": MONO, "fontSize": "0.7rem", "color": OK}}>
                                                {row.action}
                                            </p>
                                        </div>
                                    }}
                                </div>
                            }}

                            <div style={{"marginTop": "1.8rem"}}>
                                <span style={lbl(MUTED, "0.35rem")}>
                                    {"Traversal - " + str(len(swept.trace)) + " hops"}
                                </span>
                                <div style={{"overflowX": "auto"}}>
                                    {for (i, hop) in enumerate(swept.trace) {
                                        <div key={str(i)} style={{"fontFamily": MONO, "fontSize": "0.7rem", "whiteSpace": "nowrap", "color": ALARM if hop.direction == "backward" else MUTED}}>
                                            {"depth " + str(hop.depth) + "  "
                                             + ("<<<< " if hop.direction == "backward" else ">>>> ")
                                             + hop.direction + "  " + hop.kind + "  " + hop.label}
                                        </div>
                                    }}
                                </div>
                            </div>
                        </Panel>
                    }}
                </main>
            </div>
        </div>
    </div>;
}
