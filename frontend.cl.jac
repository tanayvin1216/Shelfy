"""Backshelf - the volunteer console.

Every button on this page is one walker spawn. There is no REST client, no
fetch wrapper and no serialisation code: `root spawn RecallSweep(live=...)`
crosses the wire and comes back as a typed `SweepReport`, so `row.pickup_code`
below is a real field on a real object, checked at compile time.

Layout is a fixed control rail plus a fluid results column - deliberately
asymmetric, because the rail is a fixed set of six actions and the results are
whatever the graph says. Handlers live in `frontend.impl.jac`.
"""

import from .components.Panel { Panel, Tag, Field, Action }

# Design tokens. A `glob` in a `.cl.jac` is a module-local JS variable and is
# NOT exported, so these are declared here as well as in Panel.cl.jac rather
# than imported - four duplicated strings beat an abstraction that fails the
# Vite build.
glob RULE: str = "#c9c3b6";
glob INK: str = "#15171c";
glob MUTED: str = "#6d6961";
glob MONO: str = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace";

sv import from graph { SeedPantry, SeedReport }
sv import from demo { SeedDemo, DemoReport }
sv import from intake { IntakeScan, ClearItem, IntakeReport, ClearReport }
sv import from client_search { MatchNeeds, MatchReport }
sv import from sweep { RecallSweep, SweepReport }

"""A 1x1 PNG. Under MockLLM the pixels are irrelevant - it is the placeholder
for a scan when the volunteer has not attached a photo yet."""
glob BLANK_PNG: str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

"""The browser global scope, held behind `any` because `jac check` has no typed
stubs for `FileReader` and would otherwise fail the whole module."""
glob _browser: any = globalThis;

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
    has status: str = "Nothing run yet. Start with SEED PANTRY.",
        busy: bool = False,
        seeded: SeedReport | None = None,
        demo: DemoReport | None = None,
        intake: IntakeReport | None = None,
        cleared: ClearReport | None = None,
        matched: MatchReport | None = None,
        swept: SweepReport | None = None,
        photo64: str = "",
        photoName: str = "",
        hint: str = "dented can from the back of the pallet",
        lastItemId: str = "",
        confirmedItemId: str = "",
        pickup: str = "8830",
        constraints: str = "allergic to peanuts, diabetic",
        language: str = "Spanish",
        useLiveFeed: bool = False;

    async def runSeed -> None;
    async def runScan -> None;
    async def runClearLast -> None;
    async def runClearConfirmed -> None;
    async def runSearch -> None;
    async def runSweep -> None;
    def toggleFeed(e: MouseEvent) -> None;
    def onPhoto(e: ChangeEvent) -> None;

    return <div
        style={{
            "minHeight": "100vh",
            "background": "#f2f0eb",
            "color": INK,
            "fontFamily": "'Helvetica Neue', Helvetica, Arial, sans-serif",
            "fontSize": "0.9rem",
            "lineHeight": "1.5"
        }}
    >
        <div style={{"maxWidth": "1180px", "margin": "0 auto", "padding": "2.5rem 1.5rem 5rem"}}>

            <header style={{"borderBottom": "2px solid " + INK, "paddingBottom": "1.1rem", "marginBottom": "2.5rem"}}>
                <div style={{"fontFamily": MONO, "fontSize": "0.64rem", "letterSpacing": "0.3em", "color": MUTED}}>
                    JACHACKS SF 2026 / FOOD PANTRY INTAKE + RECALL PROPAGATION
                </div>
                <h1 style={{"margin": "0.3rem 0 0", "fontSize": "2.6rem", "letterSpacing": "-0.03em", "fontWeight": "700"}}>
                    Backshelf
                </h1>
                <p style={{"margin": "0.4rem 0 0", "maxWidth": "46ch", "color": "#3d3a34"}}>
                    A recall announced on Tuesday affects the can that went out the door
                    on Saturday. This is the graph that connects the two.
                </p>
            </header>

            <div style={{"display": "grid", "gridTemplateColumns": "minmax(240px, 300px) minmax(0, 1fr)", "gap": "3rem", "alignItems": "start"}}>

                <aside style={{"position": "sticky", "top": "1.5rem"}}>
                    <div style={{"fontFamily": MONO, "fontSize": "0.62rem", "letterSpacing": "0.18em", "textTransform": "uppercase", "color": MUTED, "marginBottom": "0.6rem"}}>
                        Walkers
                    </div>
                    <Action label="1 / seed pantry + demo" onRun={runSeed} busy={busy}/>
                    <Action label="2 / intake scan" onRun={runScan} busy={busy}/>
                    <Action label="3 / clear scanned item" onRun={runClearLast} busy={busy}/>
                    <Action label="4 / client shelf search" onRun={runSearch} busy={busy}/>
                    <Action label="5 / recall sweep" onRun={runSweep} busy={busy}/>
                    <Action label="6 / clear a recalled item" onRun={runClearConfirmed} busy={busy}/>

                    <div style={{"marginTop": "1.4rem", "paddingTop": "0.8rem", "borderTop": "1px solid " + RULE}}>
                        <label style={{"display": "block", "marginBottom": "0.75rem"}}>
                            <span style={{"display": "block", "fontFamily": MONO, "fontSize": "0.62rem", "letterSpacing": "0.14em", "textTransform": "uppercase", "color": MUTED, "marginBottom": "0.25rem"}}>
                                Label photo
                            </span>
                            <input type="file" accept="image/*" capture="environment" onChange={onPhoto}
                                style={{"width": "100%", "fontFamily": MONO, "fontSize": "0.7rem"}}/>
                            <span style={{"fontFamily": MONO, "fontSize": "0.62rem", "color": MUTED}}>
                                {photoName if photoName != "" else "none - a blank placeholder is sent"}
                            </span>
                        </label>
                        <Field label="volunteer hint" value={hint} onChange={lambda v: str { hint = v; }}/>
                        <Field label="pickup code" value={pickup} onChange={lambda v: str { pickup = v; }}/>
                        <Field label="constraints (free text)" value={constraints} onChange={lambda v: str { constraints = v; }}/>
                        <Field label="language" value={language} onChange={lambda v: str { language = v; }}/>
                        <button type="button" onClick={toggleFeed}
                            style={{
                                "width": "100%", "padding": "0.4rem", "borderRadius": "0",
                                "border": "1px solid " + RULE, "background": "transparent",
                                "color": MUTED, "fontFamily": MONO, "fontSize": "0.64rem",
                                "letterSpacing": "0.1em", "textTransform": "uppercase",
                                "cursor": "pointer", "textAlign": "left"
                            }}>
                            {"recall source: live openFDA" if useLiveFeed else "recall source: cached snapshot"}
                        </button>
                    </div>

                    <p style={{"fontFamily": MONO, "fontSize": "0.66rem", "color": MUTED, "marginTop": "1.2rem", "borderLeft": "2px solid " + RULE, "paddingLeft": "0.6rem"}}>
                        {status}
                    </p>
                </aside>

                <main>
                    {if seeded is not None {
                        <Panel title="Graph" meta={"pantry " + seeded.pantry_name}>
                            <p style={{"margin": "0 0 0.5rem"}}>
                                {"nodes created this run: " + str(seeded.nodes_created)
                                 + (" (already seeded - the walker is idempotent)" if seeded.already_seeded else "")}
                            </p>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0"}}>
                                {"shelves: " + commas(seeded.shelves)}
                            </p>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0.2rem 0 0"}}>
                                {"allergen vocabulary: " + commas(seeded.allergens)}
                            </p>
                            {if demo is not None {
                                <p style={{"margin": "0.7rem 0 0"}}>
                                    {"distribution history: " + str(len(demo.handouts))
                                     + " handouts to pickup codes " + commas(demo.households)}
                                </p>
                            }}
                        </Panel>
                    }}

                    {if intake is not None {
                        <Panel title="Intake scan" meta={"byLLM " + ("MockLLM" if intake.using_mock_llm else "Gemini")}>
                            <h3 style={{"margin": "0 0 0.3rem", "fontSize": "1.15rem"}}>
                                {intake.item.brand + " " + intake.item.product}
                            </h3>
                            <div style={{"marginBottom": "0.6rem"}}>
                                <Tag text={intake.verdict} tone={"block" if intake.verdict == "discard" else ("hold" if intake.verdict == "review" else "ok")}/>
                                <Tag text={"held on " + intake.holding_shelf}/>
                                {if intake.days_past_code > 0 {
                                    <Tag text={str(intake.days_past_code) + " days past code"} tone="hold"/>
                                }}
                            </div>
                            <p style={{"margin": "0 0 0.6rem", "maxWidth": "62ch"}}>{intake.verdict_reason}</p>
                            {if intake.shelf_life_window != "" {
                                <p style={{"margin": "0 0 0.6rem", "fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED}}>
                                    {"published window: " + intake.shelf_life_window
                                     + "  -  v1 of this project would have discarded this item"}
                                </p>
                            }}
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
                        </Panel>
                    }}

                    {if cleared is not None {
                        <Panel title="Clearance gate" meta={"enforced in the walker, not the UI"}>
                            <div style={{"marginBottom": "0.5rem"}}>
                                {if cleared.refused {
                                    <Tag text="refused" tone="block"/>
                                } else {
                                    <Tag text={"cleared onto " + cleared.shelf} tone="ok"/>
                                }}
                                {for (i, rn) in enumerate(cleared.blocking_recalls) {
                                    <Tag key={str(i)} text={rn} tone="block"/>
                                }}
                            </div>
                            <p style={{"margin": "0", "maxWidth": "70ch"}}>
                                {cleared.refusal_reason if cleared.refused else "Human clearance recorded."}
                            </p>
                        </Panel>
                    }}

                    {if matched is not None {
                        <Panel title="Client shelf search" meta={"pickup " + (matched.pickup_code if matched.household_found else "(anonymous)") + " / " + matched.language}>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0 0 0.9rem"}}>
                                {"avoiding: " + (commas(matched.avoiding) if len(matched.avoiding) > 0 else "nothing")
                                 + "   /   " + str(matched.items_considered) + " items considered"}
                            </p>
                            {for (i, m) in enumerate(matched.offered) {
                                <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.7rem 0"}}>
                                    <strong>{m.item.brand + " " + m.item.product}</strong>
                                    <p style={{"margin": "0.25rem 0 0", "maxWidth": "66ch"}}>{m.explanation}</p>
                                </div>
                            }}
                            {if len(matched.withheld) > 0 {
                                <div style={{"marginTop": "1.2rem"}}>
                                    <div style={{"fontFamily": MONO, "fontSize": "0.62rem", "letterSpacing": "0.16em", "textTransform": "uppercase", "color": MUTED, "marginBottom": "0.4rem"}}>
                                        Withheld, and why
                                    </div>
                                    {for (i, w) in enumerate(matched.withheld) {
                                        <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.45rem 0", "fontSize": "0.82rem"}}>
                                            <Tag text={w.reason} tone="hold"/>
                                            {w.brand + " " + w.product + " - " + w.detail}
                                        </div>
                                    }}
                                </div>
                            }}
                            <p style={{"marginTop": "1rem", "fontSize": "0.78rem", "color": MUTED, "maxWidth": "66ch"}}>{matched.framing_note}</p>
                        </Panel>
                    }}

                    {if swept is not None {
                        <Panel title="Recall sweep" meta={swept.source + " / " + str(swept.records_seen) + " active recalls"}>
                            <p style={{"fontFamily": MONO, "fontSize": "0.72rem", "color": MUTED, "margin": "0 0 1rem"}}>
                                {str(swept.items_scanned) + " items scanned  /  " + str(swept.confirmed) + " confirmed  /  "
                                 + str(swept.possible) + " possible  /  " + str(swept.weak) + " weak"}
                            </p>

                            <div style={{"fontFamily": MONO, "fontSize": "0.62rem", "letterSpacing": "0.16em", "textTransform": "uppercase", "marginBottom": "0.4rem"}}>
                                Pull from the shelf
                            </div>
                            {for (i, row) in enumerate(swept.pull_from_shelf) {
                                <div key={str(i)} style={{"borderTop": "1px solid " + RULE, "padding": "0.6rem 0"}}>
                                    <Tag text={row.confidence} tone={"block" if row.confidence == "CONFIRMED" else "hold"}/>
                                    <strong>{row.brand + " " + row.product}</strong>
                                    <div style={{"fontFamily": MONO, "fontSize": "0.7rem", "color": MUTED, "marginTop": "0.25rem"}}>
                                        {"scanned lot " + (row.lot_code if row.lot_code != "" else "(unreadable)")
                                         + "   /   recall codes " + row.recall_code_info}
                                    </div>
                                    <p style={{"margin": "0.25rem 0 0", "maxWidth": "66ch"}}>
                                        {row.recall_number + " (" + row.classification + ") - " + row.recall_reason}
                                    </p>
                                </div>
                            }}

                            <div style={{"marginTop": "1.6rem", "borderLeft": "3px solid #a4231d", "paddingLeft": "0.9rem"}}>
                                <div style={{"fontFamily": MONO, "fontSize": "0.62rem", "letterSpacing": "0.16em", "textTransform": "uppercase", "marginBottom": "0.5rem"}}>
                                    Households to notify - reached by walking Received backwards
                                </div>
                                {if len(swept.notify_households) == 0 {
                                    <p style={{"margin": "0", "color": MUTED}}>
                                        No distribution history in this graph yet. Run SEED PANTRY + DEMO first.
                                    </p>
                                }}
                                {for (i, h) in enumerate(swept.notify_households) {
                                    <div key={str(i)} style={{"padding": "0.5rem 0", "borderTop": "1px solid " + RULE}}>
                                        <span style={{"fontFamily": MONO, "fontSize": "1.4rem", "letterSpacing": "0.08em"}}>{h.pickup_code}</span>
                                        <Tag text={h.confidence} tone={"block" if h.confidence == "CONFIRMED" else "hold"}/>
                                        <Tag text={"lang " + h.preferred_language}/>
                                        <Tag text={h.notify_contact if h.notify_contact != "" else "no contact on file"}/>
                                        <p style={{"margin": "0.25rem 0 0", "maxWidth": "70ch"}}>{h.message}</p>
                                    </div>
                                }}
                                <p style={{"margin": "0.8rem 0 0", "fontSize": "0.78rem", "color": MUTED, "maxWidth": "60ch"}}>
                                    A pickup code is the entire identity of a household here. No name, no
                                    address, no phone number is stored anywhere in the graph.
                                </p>
                            </div>

                            <div style={{"marginTop": "1.6rem"}}>
                                <div style={{"fontFamily": MONO, "fontSize": "0.62rem", "letterSpacing": "0.16em", "textTransform": "uppercase", "color": MUTED, "marginBottom": "0.4rem"}}>
                                    Traversal
                                </div>
                                {for (i, hop) in enumerate(swept.trace) {
                                    <div key={str(i)} style={{"fontFamily": MONO, "fontSize": "0.7rem", "color": MUTED}}>
                                        {"depth " + str(hop.depth) + "  " + ("<<< " if hop.direction == "backward" else ">>> ")
                                         + hop.direction + "  " + hop.kind + "  " + hop.label}
                                    </div>
                                }}
                            </div>
                        </Panel>
                    }}
                </main>
            </div>
        </div>
    </div>;
}
