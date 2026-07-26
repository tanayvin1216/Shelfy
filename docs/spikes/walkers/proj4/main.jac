import from graph { Supplier, Lot, Sent }
import from walkers { RecallSweep }

with entry {
    s = Supplier(name="Valley");
    root ++> s;
    l = Lot(code="L-1");
    s +>:Sent:+> l;
    print((root spawn RecallSweep(lot_jid=jid(l))).reports);
}
