"""Intake screen: label + lot, plus a phone-camera label scan."""
sv import from ..services { Item, AddItem, ScanLabel }

def:pub IntakeForm() -> JsxElement {
    has label: str = "",
        lot: str = "",
        added: list[Item] = [],
        scan_note: str = "",
        preview: str = "";

    async def submit(e: FormEvent) -> None;
    async def on_photo(e: ChangeEvent) -> None;

    return <section style={{"padding": "1rem"}}>
        <h1>Intake</h1>
        <form onSubmit={submit}>
            <input
                value={label}
                placeholder="Label"
                onChange={lambda e: ChangeEvent { label = e.target.value; }}
            />
            <input
                value={lot}
                placeholder="Lot"
                onChange={lambda e: ChangeEvent { lot = e.target.value; }}
            />
            <button type="submit">Add</button>
        </form>

        <h2>Scan label with camera</h2>
        <input
            type="file"
            accept="image/*"
            capture="environment"
            onChange={on_photo}
        />
        {if preview {
            <img src={preview} alt="label preview" width={180} />
        }}
        <p>{scan_note}</p>

        <ul>
            {for it in added {
                <li key={jid(it)}>{it.label} / {it.lot}</li>
            }}
        </ul>
    </section>;
}
