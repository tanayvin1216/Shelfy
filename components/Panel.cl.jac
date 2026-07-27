"""Structural primitives for the Backshelf console.

Aesthetic direction: **industrial**. Exposed 1px rules, zero border radius,
monospace small-caps section labels, a warm paper ground and four ink-on-paper
accents. Reference bar: the printed intake sheet a food bank actually clips to
a board, and Braun/Dieter-Rams instrument labelling.

There is no shadow, no gradient, no blur, no rounded pill and no hover
transform in this file, and there must never be one - a volunteer reads this
on a phone under warehouse lighting, and decoration costs contrast.

Nothing here is a floating card. A `Panel` is a titled region of a single
document; a `Beat` is a rule-marked callout inside it. Weight comes from type
scale and from which side of the rule the ink sits on.
"""

glob PAPER: str = "#f2f0eb";
glob CARD: str = "#fffdf8";
glob RULE: str = "#c9c3b6";
glob INK: str = "#15171c";
glob MUTED: str = "#6d6961";
glob ALARM: str = "#a4231d";
glob HOLD: str = "#8a5d0b";
glob OK: str = "#2c6141";
glob MONO: str = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace";

"""The one small-caps monospace label used for every section marker on the
page. Declared once so the rhythm cannot drift between components."""
def _label(color: str, gap: str) -> dict[str, object] {
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

"""Map a tone name onto the accent it prints in."""
def _shade(tone: str) -> str {
    if tone == "block" {
        return ALARM;
    }
    if tone == "hold" {
        return HOLD;
    }
    if tone == "ok" {
        return OK;
    }
    return MUTED;
}

def:pub Panel(title: str, meta: str = "", children: any = None) -> JsxElement {
    return <section
        style={{
            "borderTop": "2px solid " + INK,
            "paddingTop": "0.55rem",
            "marginBottom": "2.75rem"
        }}
    >
        <header
            style={{
                "display": "flex",
                "flexWrap": "wrap",
                "alignItems": "baseline",
                "justifyContent": "space-between",
                "gap": "0.5rem 1rem",
                "marginBottom": "1rem"
            }}
        >
            <h2
                style={{
                    "margin": "0",
                    "fontFamily": MONO,
                    "fontSize": "0.74rem",
                    "letterSpacing": "0.2em",
                    "textTransform": "uppercase",
                    "fontWeight": "700"
                }}
            >{title}</h2>
            <span
                style={{
                    "fontFamily": MONO,
                    "fontSize": "0.66rem",
                    "color": MUTED
                }}
            >{meta}</span>
        </header>
        {children}
    </section>;
}

"""A callout that carries one of the demo's beats.

Used for the two moments the page has to say out loud rather than log: the
past-date item v1 would have destroyed, and the clearance the walker refuses.
The 6px rule on the left is the whole ornament budget.
"""
def:pub Beat(kicker: str, headline: str, tone: str = "hold",
             children: any = None) -> JsxElement {
    shade = _shade(tone);
    return <div
        style={{
            "borderLeft": "6px solid " + shade,
            "borderTop": "1px solid " + RULE,
            "borderRight": "1px solid " + RULE,
            "borderBottom": "1px solid " + RULE,
            "background": CARD,
            "padding": "0.85rem 1.1rem 1rem",
            "margin": "0 0 1.5rem"
        }}
    >
        <span style={_label(shade, "0.15rem")}>{kicker}</span>
        <div
            style={{
                "fontSize": "1.5rem",
                "lineHeight": "1.12",
                "letterSpacing": "-0.025em",
                "fontWeight": "700",
                "margin": "0 0 0.5rem",
                "maxWidth": "26ch"
            }}
        >{headline}</div>
        {children}
    </div>;
}

"""The lot-code comparison, side by side.

Section 4 forbids auto-discarding on a brand match, which means a human has to
compare two strings. This component is that comparison and nothing else: what
is stamped on the package, what the FDA published, and the tier that follows.
"""
def:pub CodeCompare(scanned: str, recalled: str, confidence: str,
                    note: str = "") -> JsxElement {
    shade = _shade("block" if confidence == "CONFIRMED"
                   else ("hold" if confidence == "POSSIBLE" else "neutral"));
    return <div
        style={{
            "border": "1px solid " + RULE,
            "background": CARD,
            "margin": "0.55rem 0 0"
        }}
    >
        <div style={{"display": "flex", "flexWrap": "wrap"}}>
            <div
                style={{
                    "flex": "1 1 11rem",
                    "padding": "0.5rem 0.8rem",
                    "borderRight": "1px solid " + RULE,
                    "borderBottom": "1px solid " + RULE
                }}
            >
                <span style={_label(MUTED, "0.2rem")}>Stamped on this package</span>
                <div
                    style={{
                        "fontFamily": MONO,
                        "fontSize": "1.05rem",
                        "letterSpacing": "0.06em",
                        "color": INK if scanned != "" else MUTED
                    }}
                >{scanned if scanned != "" else "not legible"}</div>
            </div>
            <div
                style={{
                    "flex": "2 1 16rem",
                    "padding": "0.5rem 0.8rem",
                    "borderBottom": "1px solid " + RULE
                }}
            >
                <span style={_label(MUTED, "0.2rem")}>FDA recall code list</span>
                <div
                    style={{
                        "fontFamily": MONO,
                        "fontSize": "1.05rem",
                        "letterSpacing": "0.06em",
                        "color": INK if recalled != "" else MUTED
                    }}
                >{recalled if recalled != "" else "none published"}</div>
            </div>
        </div>
        <div
            style={{
                "padding": "0.4rem 0.8rem",
                "fontFamily": MONO,
                "fontSize": "0.68rem",
                "lineHeight": "1.45",
                "color": shade
            }}
        >
            <strong style={{"letterSpacing": "0.12em"}}>{confidence}</strong>
            {"  " + note if note != "" else ""}
        </div>
    </div>;
}

"""One number in the sweep's counter row. The number is the type, the caption
is the footnote - not the other way round."""
def:pub Stat(value: str, label: str, tone: str = "neutral") -> JsxElement {
    shade = _shade(tone);
    return <div
        style={{
            "flex": "1 1 5.5rem",
            "borderLeft": "2px solid " + shade,
            "paddingLeft": "0.55rem"
        }}
    >
        <div
            style={{
                "fontFamily": MONO,
                "fontSize": "1.6rem",
                "lineHeight": "1",
                "letterSpacing": "-0.02em",
                "color": shade if tone != "neutral" else INK
            }}
        >{value}</div>
        <span style={_label(MUTED, "0")}>{label}</span>
    </div>;
}

def:pub Tag(text: str, tone: str = "neutral") -> JsxElement {
    shade = _shade(tone);
    return <span
        style={{
            "display": "inline-block",
            "fontFamily": MONO,
            "fontSize": "0.62rem",
            "letterSpacing": "0.12em",
            "textTransform": "uppercase",
            "padding": "0.15rem 0.4rem",
            "border": "1px solid " + shade,
            "color": shade,
            "marginRight": "0.35rem",
            "marginBottom": "0.2rem",
            "whiteSpace": "nowrap"
        }}
    >{text}</span>;
}

"""`kind` is the input's HTML type. It exists for one caller - the API key
field, which must be `password` so the key is not readable over a volunteer's
shoulder or in a screenshot of the console."""
def:pub Field(label: str, value: str, onChange: Callable[[str], None],
              placeholder: str = "", kind: str = "text") -> JsxElement {
    def handle(e: ChangeEvent) {
        onChange(e.target.value);
    }
    return <label style={{"display": "block", "marginBottom": "0.8rem"}}>
        <span style={_label(MUTED, "0.25rem")}>{label}</span>
        <input
            type={kind}
            value={value}
            onChange={handle}
            placeholder={placeholder}
            style={{
                "width": "100%",
                "boxSizing": "border-box",
                "padding": "0.5rem",
                "border": "1px solid " + RULE,
                "borderRadius": "0",
                "background": CARD,
                "color": INK,
                "fontFamily": MONO,
                "fontSize": "0.82rem"
            }}
        />
    </label>;
}

"""A small button that sits in a row with a sibling.

The `Action` buttons in the running order are full width and numbered because
each one is a beat of the demo. Saving a key is not a beat, so this is the
quieter treatment: same square corners and same mono small caps, outline unless
it is the primary of the pair.
"""
def:pub SmallButton(label: str, onRun: Callable[[], None],
                    primary: bool = False, busy: bool = False) -> JsxElement {
    def handle(e: MouseEvent) {
        onRun();
    }
    return <button
        type="button"
        onClick={handle}
        disabled={busy}
        style={{
            "flex": "1 1 auto",
            "padding": "0.45rem 0.3rem",
            "border": "1px solid " + ("#d9d4c8" if busy else INK),
            "borderRadius": "0",
            "marginRight": "-1px",
            "background": (INK if primary else "transparent") if not busy else "#e8e4da",
            "color": (PAPER if primary else INK) if not busy else MUTED,
            "fontFamily": MONO,
            "fontSize": "0.64rem",
            "letterSpacing": "0.12em",
            "textTransform": "uppercase",
            "cursor": "wait" if busy else "pointer"
        }}
    >{label}</button>;
}

"""One segment of a `Choice`. Its own component so the option string is closed
over by the handler rather than read back out of a stale loop variable."""
def:pub ChoiceButton(option: str, active: bool,
                     onPick: Callable[[str], None]) -> JsxElement {
    def handle(e: MouseEvent) {
        onPick(option);
    }
    return <button
        type="button"
        onClick={handle}
        style={{
            "flex": "1 1 auto",
            "padding": "0.4rem 0.3rem",
            "border": "1px solid " + (INK if active else RULE),
            "borderRadius": "0",
            "marginRight": "-1px",
            "background": INK if active else "transparent",
            "color": PAPER if active else MUTED,
            "fontFamily": MONO,
            "fontSize": "0.66rem",
            "letterSpacing": "0.1em",
            "textTransform": "uppercase",
            "cursor": "pointer"
        }}
    >{option}</button>;
}

"""A segmented control. On stage the language switch has to be one tap, not a
text field someone retypes while a judge waits."""
def:pub Choice(label: str, options: list[str], value: str,
               onPick: Callable[[str], None]) -> JsxElement {
    return <div style={{"marginBottom": "0.8rem"}}>
        <span style={_label(MUTED, "0.25rem")}>{label}</span>
        <div style={{"display": "flex"}}>
            {for (i, opt) in enumerate(options) {
                <ChoiceButton key={str(i)} option={opt} active={opt == value}
                              onPick={onPick}/>
            }}
        </div>
    </div>;
}

"""One walker, one button. `step` is the demo-script beat number so the rail
reads as a running order on a projector."""
def:pub Action(step: str, label: str, onRun: Callable[[], None],
               busy: bool = False, tone: str = "neutral") -> JsxElement {
    def handle(e: MouseEvent) {
        onRun();
    }
    ground = _shade(tone) if tone != "neutral" else INK;
    return <button
        type="button"
        onClick={handle}
        disabled={busy}
        style={{
            "display": "flex",
            "alignItems": "baseline",
            "gap": "0.55rem",
            "width": "100%",
            "padding": "0.6rem",
            "marginBottom": "0.45rem",
            "border": "1px solid " + ("#d9d4c8" if busy else ground),
            "borderRadius": "0",
            "background": "#e8e4da" if busy else ground,
            "color": MUTED if busy else "#f7f5ef",
            "fontFamily": MONO,
            "fontSize": "0.7rem",
            "letterSpacing": "0.1em",
            "textTransform": "uppercase",
            "cursor": "wait" if busy else "pointer",
            "textAlign": "left"
        }}
    >
        <span style={{"opacity": "0.55", "fontSize": "0.8rem"}}>{step}</span>
        <span style={{"flex": "1 1 auto"}}>{label}</span>
    </button>;
}
