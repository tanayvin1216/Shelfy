# Deploying Backshelf to Railway

One process serves the API *and* the client bundle, so this is a single service.
The CLI is already installed (`railway 5.28.1`). You only need to log in.

## The three commands

```bash
railway login                 # opens a browser — this is the only step that needs you
railway init                  # create the project; name it "backshelf"
railway up                    # builds the Dockerfile and deploys
```

Then generate a public URL:

```bash
railway domain
```

## The API key — the one place

Everything reads a single variable. Set it once, on Railway:

```bash
railway variables --set GEMINI_API_KEY=your_key_here
railway up                    # redeploy so the new variable is picked up
```

Locally the same key goes in `.env` (gitignored) and nowhere else.

Without it the app runs on `DemoLLM` and returns canned extractions — every code path
works, but the label scan is not real.

## Seed after deploying — this is not optional

Persistence is SQLite inside the container. **A deploy wipes it.** Seed *after* your
final deploy, and do not redeploy before demoing.

```bash
URL=$(railway domain | tr -d '[:space:]')
curl -X POST https://$URL/walker/SeedPantry -H 'Content-Type: application/json' -d '{}'
curl -X POST https://$URL/walker/SeedDemo   -H 'Content-Type: application/json' -d '{}'
```

Or point the rehearsal script at it:

```bash
BACKSHELF_URL=https://$URL ./scripts/demo.sh
```

## Checks that catch the common failures

```bash
railway logs                  # look for "Server ready"
curl https://$URL/health      # built-in liveness probe
curl https://$URL/walkers     # should list all six walkers
open https://$URL             # the client console
```

## Things that will bite, and why they are already handled

- **`jac start` exits when stdin closes.** The container command ends in `< /dev/null`.
  Without it the process dies immediately and the deploy looks like a crash loop.
- **The client bundle needs node.** The image is `node:22` with Python added, not a Python
  buildpack — a Python-only image fails at the vite build step.
- **`numReplicas: 1` in `railway.json` is deliberate.** Multi-replica plus SQLite corrupts
  the graph. Do not scale this up without setting `MONGODB_URI`.
- **`.dockerignore` excludes `.venv` and `node_modules`** so macOS-built artifacts never
  reach the Linux image.

## If the deploy fails and time is short

Fall back to a tunnel — the backend is identical, only the hosting changes:

```bash
./.venv/bin/jac start main.jac < /dev/null &
npx cloudflared tunnel --url http://localhost:8000
```

Keep every walker in Jac either way. The fallback surrenders the hosting, never the backend.
