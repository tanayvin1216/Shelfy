"""Backshelf - the Gemini key, settable from the running app.

    POST /walker/LlmStatus    what the next byLLM call will run on
    POST /walker/SetLlmKey    paste a key, or send a blank one to clear it

Before this module the only way to give Backshelf a key was an env var and a
restart: `.env` plus `jac start` locally, a service variable plus a redeploy on
Railway. Neither is available to a volunteer holding a phone, and neither is
available on stage. Now the key lives on an `LlmConfig` node hanging off the
Pantry, and `llm.sv.jac`'s router reads it on every call - so a key pasted into
the web form is live on the very next scan, and survives a restart because
reachability from root is the whole persistence story.

THE SECRET NEVER COMES BACK OUT. Both walkers here report `_mask_key(...)` and
nothing else; `api_key` is read in exactly two places in the repo, both of them
inside `llm.sv.jac`, and provider error text is redacted before it is logged or
reported. See the node's own docstring in `graph.sv.jac` for the exposure this
design accepts on purpose.
"""

import from graph { LlmConfig, _find_llm_config, _get_llm_config, _now }
import from llm {
    DEFAULT_MODEL_NAME,
    _mask_key, _using_mock_llm, _llm_source, _llm_model_name, _llm_last_error
}

obj LlmStatusView {
    """What the console shows in the settings panel. Every field here is safe
    to print on a projector."""
    has configured: bool,
        masked_key: str,
        model: str,
        using_mock_llm: bool,
        source: str,
        updated_at: str,
        last_error: str;
}

obj SetKeyView {
    has configured: bool,
        masked_key: str,
        model: str,
        using_mock_llm: bool,
        source: str,
        updated_at: str,
        cleared: bool,
        message: str;
}

"""Read the stored key back as a mask. Reads the graph directly rather than the
resolved model, so the panel can show WHICH key is on file even when the
resolver has fallen through to the environment."""
def _stored_view -> LlmStatusView {
    cfg = _find_llm_config();
    stored = cfg.api_key if cfg is not None else "";
    stamp = cfg.updated_at if cfg is not None else "";
    source = _llm_source();
    masked = _mask_key(stored) if source == "graph" else "";
    return LlmStatusView(
        configured=(source != "none"),
        masked_key=masked,
        model=_llm_model_name(),
        using_mock_llm=_using_mock_llm(),
        source=source,
        updated_at=stamp,
        last_error=_llm_last_error()
    );
}

walker:pub LlmStatus {
    """What the next byLLM call will actually run on.

    `source` is the honest answer to "why is this on MockLLM": `graph` means a
    key was pasted in here, `env` means GEMINI_API_KEY was set before the
    process started, `none` means there is no key anywhere and every scan will
    come back as the same canned label.
    """

    has reports: list[LlmStatusView] = [];

    can read with Root entry {
        report _stored_view();
        disengage;
    }
}

walker:pub SetLlmKey {
    """Store a Gemini key in the graph, or clear it.

    An empty or whitespace-only `api_key` is not an error and not a no-op: it
    is the explicit CLEAR, and it puts the process straight back on MockLLM
    with no restart. That is the undo path, and the demo needs it as much as it
    needs the set path.

    The response is deliberately not a mirror of the request. It reports the
    mask, never the key - so this endpoint cannot be used as an oracle to read
    back a key somebody else set, and a screenshot of the console is safe.
    """

    has api_key: str = "";
    has model_name: str = "";
    has reports: list[SetKeyView] = [];

    can store with Root entry {
        incoming = self.api_key.strip();
        named = self.model_name.strip();

        # The response envelope serialises the walker itself into `data.result`,
        # `has` fields and all - so leaving the key on `self` posts it straight
        # back to the browser and into anything that logs the response body.
        # Caught by grepping a real response for the literal key, not by
        # reading the code. Blank it the moment it has been copied.
        self.api_key = "";

        cfg = _get_llm_config();
        cfg.api_key = incoming;
        cfg.model_name = named;
        cfg.updated_at = _now();

        # Resolution is fingerprinted on the stored value, so writing the node
        # is the whole invalidation - there is no cache to poke and nothing to
        # restart. The status below is read back AFTER the write, which is what
        # makes it a verification rather than an echo.
        view = _stored_view();

        cleared = (incoming == "");
        report SetKeyView(
            configured=view.configured,
            masked_key=view.masked_key,
            model=view.model,
            using_mock_llm=view.using_mock_llm,
            source=view.source,
            updated_at=cfg.updated_at,
            cleared=cleared,
            message=(
                "Key cleared. Scans are back on MockLLM and will return the "
                "same canned label every time."
                if cleared
                else "Key stored in the graph. The next scan runs on "
                     + (named if named != "" else DEFAULT_MODEL_NAME)
                     + " - no restart."
            )
        );
        disengage;
    }
}
