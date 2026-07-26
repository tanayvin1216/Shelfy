"""Workarounds so Image(...) passes `jac check` (byllm 0.6.19 annotates url as a string literal)."""
import from byllm.lib { Image }

def load_label(path: str) -> Image {
    p: any = path;
    return Image(p);
}

with entry {
    a = load_label("label.png");
    print("via any-typed local:", a.mime_type, len(a.url));

    # inline `as any` cast
    b = Image("label.png" as any);
    print("via as-any cast:", b.mime_type, len(b.url));
}
