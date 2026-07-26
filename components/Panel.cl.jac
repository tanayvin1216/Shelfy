"""Structural primitives for the Backshelf console.

Industrial direction: exposed 1px rules, zero radius, monospace section labels
in small caps. A panel is a titled region of the grid, not a floating card -
there is no shadow, no gradient and no hover transform anywhere in this file.
"""

glob RULE: str = "#c9c3b6";
glob INK: str = "#15171c";
glob MUTED: str = "#6d6961";
glob MONO: str = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace";

def:pub Panel(title: str, meta: str = "", children: any = None) -> JsxElement {
    return <section
        style={{
            "borderTop": "1px solid " + INK,
            "paddingTop": "0.55rem",
            "marginBottom": "2.25rem"
        }}
    >
        <header
            style={{
                "display": "flex",
                "alignItems": "baseline",
                "justifyContent": "space-between",
                "gap": "1rem",
                "marginBottom": "0.9rem"
            }}
        >
            <h2
                style={{
                    "margin": "0",
                    "fontFamily": MONO,
                    "fontSize": "0.72rem",
                    "letterSpacing": "0.18em",
                    "textTransform": "uppercase",
                    "fontWeight": "600"
                }}
            >{title}</h2>
            <span
                style={{
                    "fontFamily": MONO,
                    "fontSize": "0.68rem",
                    "color": MUTED,
                    "textAlign": "right"
                }}
            >{meta}</span>
        </header>
        {children}
    </section>;
}

def:pub Tag(text: str, tone: str = "neutral") -> JsxElement {
    colors: dict[str, str] = {
        "neutral": MUTED,
        "block": "#a4231d",
        "hold": "#8a5d0b",
        "ok": "#2c6141"
    };
    shade = colors.get(tone, MUTED);
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
            "whiteSpace": "nowrap"
        }}
    >{text}</span>;
}

def:pub Field(label: str, value: str, onChange: Callable[[str], None],
              placeholder: str = "") -> JsxElement {
    def handle(e: ChangeEvent) {
        onChange(e.target.value);
    }
    return <label style={{"display": "block", "marginBottom": "0.75rem"}}>
        <span
            style={{
                "display": "block",
                "fontFamily": MONO,
                "fontSize": "0.62rem",
                "letterSpacing": "0.14em",
                "textTransform": "uppercase",
                "color": MUTED,
                "marginBottom": "0.25rem"
            }}
        >{label}</span>
        <input
            type="text"
            value={value}
            onChange={handle}
            placeholder={placeholder}
            style={{
                "width": "100%",
                "boxSizing": "border-box",
                "padding": "0.45rem 0.5rem",
                "border": "1px solid " + RULE,
                "borderRadius": "0",
                "background": "#fffdf8",
                "color": INK,
                "fontFamily": MONO,
                "fontSize": "0.8rem"
            }}
        />
    </label>;
}

def:pub Action(label: str, onRun: Callable[[], None], busy: bool = False) -> JsxElement {
    def handle(e: MouseEvent) {
        onRun();
    }
    return <button
        type="button"
        onClick={handle}
        disabled={busy}
        style={{
            "display": "block",
            "width": "100%",
            "padding": "0.55rem 0.6rem",
            "marginBottom": "0.5rem",
            "border": "1px solid " + INK,
            "borderRadius": "0",
            "background": "#e8e4da" if busy else INK,
            "color": MUTED if busy else "#f7f5ef",
            "fontFamily": MONO,
            "fontSize": "0.7rem",
            "letterSpacing": "0.12em",
            "textTransform": "uppercase",
            "cursor": "wait" if busy else "pointer",
            "textAlign": "left"
        }}
    >{label}</button>;
}
