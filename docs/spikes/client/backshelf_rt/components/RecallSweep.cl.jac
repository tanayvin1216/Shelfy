sv import from ..services { Item, SweepRecall }

def:pub RecallSweep() -> JsxElement {
    has lot: str = "",
        hits: list[Item] = [],
        swept: bool = False;

    async def sweep(e: FormEvent) -> None;

    return <section style={{"padding": "1rem"}}>
        <h1>Recall sweep</h1>
        <form onSubmit={sweep}>
            <input
                value={lot}
                placeholder="Recalled lot"
                onChange={lambda e: ChangeEvent { lot = e.target.value; }}
            />
            <button type="submit">Sweep</button>
        </form>
        {if swept {
            <p>{"Flagged " + str(len(hits)) + " item(s)."}</p>
        }}
        <ul>
            {for it in hits {
                <li key={jid(it)}>{it.label} / {it.lot}</li>
            }}
        </ul>
    </section>;
}
