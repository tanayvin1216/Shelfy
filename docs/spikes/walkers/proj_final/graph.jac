node Supplier { has name: str; }
node Lot      { has code: str; has recalled: bool = False; }
edge Sent: Supplier --> Lot {}
