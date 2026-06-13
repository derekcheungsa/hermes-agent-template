# Hermes Agent — Railway Template

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on [Railway](https://railway.app) with a web-based admin dashboard for configuration, gateway management, and user pairing.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-agent-ai?referralCode=QXdhdr&utm_medium=integration&utm_source=template&utm_campaign=generic)

> Hermes Agent is an autonomous AI agent by [Nous Research](https://nousresearch.com/) that lives on your server, connects to your messaging channels (Telegram, Discord, Slack, etc.), and gets more capable the longer it runs.

<!-- TODO: Add dashboard screenshot -->
<!-- ![Dashboard](docs/dashboard.png) -->

## Features

- **Admin Dashboard** — dark-themed UI to configure providers, channels, tools, and manage the gateway
- **One-Page Setup** — provider dropdown, checkbox-based channel/tool toggles — no config files to edit
- **Gateway Management** — start, stop, restart the Hermes gateway from the browser
- **Live Status** — stat cards for gateway state, uptime, model, and pending pairing requests
- **Live Logs** — streaming gateway log viewer
- **User Pairing** — approve or deny users who message your bot, revoke access anytime
- **Basic Auth** — password-protected admin panel
- **Reset Config** — one-click reset to start fresh

## Getting Started

The easiest way to get started:

### 1. Get an LLM Provider Key (free)

1. Register for free at [OpenRouter](https://openrouter.ai/)
2. Create an API key from your [OpenRouter dashboard](https://openrouter.ai/keys)
3. Pick a free model from the [model list sorted by price](https://openrouter.ai/models?order=pricing-low-to-high) (e.g. `google/gemma-3-1b-it:free`, `meta-llama/llama-3.1-8b-instruct:free`)

### 2. Set Up a Telegram Bot (fastest channel)

Hermes Agent interacts entirely through messaging channels — there is no chat UI like ChatGPT. Telegram is the quickest to set up:

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot`, follow the prompts, and copy the **Bot Token**
3. Send a message to your new bot — it will appear as a pairing request in the admin dashboard
4. To find your Telegram user ID, message [@userinfobot](https://t.me/userinfobot)

### 3. Create a Railway Volume (required)

> **Without this step, all configuration — API keys, channel tokens, approved users — is permanently lost every time the container restarts or redeploys.**

1. In the [Railway dashboard](https://railway.app/), open your project
2. Click your service → **Storage** → **New Volume**
3. Set the mount path to `/data`

### 4. Deploy to Railway

1. Click the **Deploy on Railway** button above
2. Set the `ADMIN_PASSWORD` environment variable (or a random one will be generated and printed to deploy logs)
3. Open your app URL — log in with username `admin` and your password

### 5. Configure in the Admin Dashboard

1. **LLM Provider** — select OpenRouter from the dropdown, paste your API key, enter the model name
2. **Messaging Channel** — check Telegram, paste the Bot Token from BotFather
3. Click **Save & Start** — the gateway will start and your bot goes live

### 6. Start Chatting

Message your Telegram bot. If you're a new user, a pairing request will appear in the admin dashboard under **Users** — click **Approve**, and you're in.

<!-- TODO: Add Telegram chat screenshot -->
<!-- ![Telegram Example](docs/telegram-example.png) -->

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Web server port (set automatically by Railway) |
| `ADMIN_USERNAME` | `admin` | Admin login username |
| `ADMIN_PASSWORD` | *(auto-generated)* | Admin login password — if unset, a random password is printed to logs |
| `API_SERVER_ENABLED` | `false` | Set `true` to expose the OpenAI-compatible API at `/v1` (see below) |
| `API_SERVER_KEY` | *(unset)* | **Required** when the API is enabled — Bearer token clients must send. Use a strong random value (`openssl rand -hex 32`) |
| `API_SERVER_MODEL_NAME` | `hermes-agent` | Model id reported by `/v1/models` and accepted by `/v1/chat/completions` |

All other configuration (LLM provider, model, channels, tools) is managed through the admin dashboard.

## OpenAI-Compatible API (`/v1`)

Hermes can serve an OpenAI-compatible API so external clients (ElevenLabs, Open WebUI, any OpenAI SDK) can talk to your agent. This template proxies it on the **same public Railway URL** as the dashboard — no extra port, no Caddy/nginx.

1. Set these Railway variables:
   ```
   API_SERVER_ENABLED=true
   API_SERVER_KEY=<openssl rand -hex 32>
   API_SERVER_MODEL_NAME=hermes-agent
   ```
2. Redeploy and make sure the gateway is running (Save & Start in the dashboard).
3. Point your client at `https://<your-app>.up.railway.app/v1` using `API_SERVER_KEY` as the Bearer token.

Verify:
```bash
curl -s https://<your-app>.up.railway.app/v1/models \
  -H "Authorization: Bearer $API_SERVER_KEY"
# → {"data":[{"id":"hermes-agent",...}]}
```

The API server binds to loopback inside the container and is reached only through the proxy; `/v1/*` bypasses the dashboard's cookie login and is authenticated solely by `API_SERVER_KEY`. Streaming (`stream=true`) is supported.

### Connect ElevenLabs

In the ElevenLabs Conversational AI agent settings, choose a **Custom LLM**:

- **Server URL:** `https://<your-app>.up.railway.app/v1`
- **Model ID:** `hermes-agent` (must match `API_SERVER_MODEL_NAME`)
- **API Key:** your `API_SERVER_KEY`

ElevenLabs sends it as `Authorization: Bearer <API_SERVER_KEY>`, which the proxy forwards to the API server. Leave streaming enabled — it's supported end-to-end.

## Supported Providers

OpenRouter, DeepSeek, DashScope, GLM / Z.AI, Kimi, MiniMax, HuggingFace, NVIDIA

## Supported Channels

Telegram, Discord, Slack, WhatsApp, Email, Mattermost, Matrix

## Supported Tool Integrations

Parallel (search), Firecrawl (scraping), Tavily (search), FAL (image gen), Browserbase, GitHub, OpenAI Voice (Whisper/TTS), Honcho (memory)

## Architecture

```
Railway Container
├── Python Admin Server (Starlette + Uvicorn) — listens on $PORT
│   ├── /            — Hermes dashboard       (proxied → 127.0.0.1:9119, cookie auth)
│   ├── /setup/*     — Setup wizard + mgmt API (cookie auth)
│   ├── /v1/*        — OpenAI-compatible API   (proxied → 127.0.0.1:8642, Bearer auth)
│   └── /health      — Health check (no auth)
└── hermes gateway   — Managed async subprocess
    └── api_server platform — binds 127.0.0.1:8642 when API_SERVER_ENABLED=true
```

The admin server runs on `$PORT` and manages the Hermes gateway as a child process. Config is stored in `/data/.hermes/.env` and `/data/.hermes/config.yaml`. Gateway stdout/stderr is captured into a ring buffer and streamed to the Logs panel.

## Running Locally

```bash
docker build -t hermes-agent .
docker run --rm -it -p 8080:8080 -e PORT=8080 -e ADMIN_PASSWORD=changeme -v hermes-data:/data hermes-agent
```

Open `http://localhost:8080` and log in with `admin` / `changeme`.

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by [Nous Research](https://nousresearch.com/)
- UI inspired by [OpenClaw](https://github.com/praveen-ks-2001/openclaw-railway) admin template
