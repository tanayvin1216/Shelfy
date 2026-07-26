sv import from ..services { Item, ListItems }

def:pub ShelfList() -> JsxElement {
    has items: list[Item] = [];

    can with entry { load(); }
    async def load() -> None;

    return <section style={{"padding": "1rem"}}>
        <h1>Shelf</h1>
        {if len(items) == 0 {
            <p>Nothing on the shelf.</p>
            skip;
        }}
        <ul>
            {for it in items {
                <li key={jid(it)}>
                    {it.label} / {it.lot} {" "}
                    {"RECALLED" if it.recalled else "ok"}
                </li>
            }}
        </ul>
    </section>;
}
