import from graph { Lot }
import from walkers { Sweep }
with entry { root ++> Lot(code="A"); print((root spawn Sweep()).reports); }
