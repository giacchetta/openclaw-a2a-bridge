# AGENTS.md

Before reading user requests or modifying ANY file, you MUST follow this exact execution sequence:

1. **STEP 1 — GUARDRAILS CHECK**: Read `.agents/guardrails/*.md`. Any violation results in immediate execution termination.
2. **STEP 2 — SYSTEM CORE RULES**: Read `.agents/core/*.md` to establish non-negotiable coding and quality standards.
3. **STEP 3 — READ LOCAL ARCHITECTURE**: Read Section 2 below (`# Local Architecture Blueprint`). DO NOT execute recursive directory exploration scripts or spawn sub-agents to explore the codebase.
4. **STEP 4 — EXECUTE TASK**: Perform the task adhering strictly to the above.
5. **STEP 5 — ARCHITECTURE PROTOCOL**: Read `.agents/protocols/agents-md-protocol.md`. If your changes modified system boundaries, directory structures, or APIs, you MUST update Section 2 of this `AGENTS.md` file before completing your task.

---

# 🏛️ Local Architecture Blueprint

> **Document status:** Production-ready PoC blueprint.
> **Last updated:** 2026-08-11

---
## 📝 Companion Document: `README.md`

This repository also ships a human-oriented **[`README.md`](./README.md)** — a friendly, visual tour of the project (Mermaid diagrams, the three-node loop, the fleet, quick-start commands).

**Keep `README.md` in sync with this document.** Whenever you change anything in this `AGENTS.md` that affects the user-facing story — the fleet inventory (§9), the architecture (§2), the request flow (§5), the sub-agent loop (§8), or the quick-start commands (§10) — update `README.md` to match. Concretely:

- The Mermaid diagrams in `README.md` must reflect the current architecture in §2 and §5.
- The "Meet the fleet" table must match §9's *Currently Deployed Services*.
- The three-node loop diagram and table must match §8's *Standardized Sub-Agent Loop*.
- The quick-start commands must match §10's *Operational Notes*.
- `README.md` uses **Mermaid** (not ASCII art) for all graphics; do not regress to ASCII.

`AGENTS.md` remains the authoritative technical reference; `README.md` is the approachable summary. When the two disagree, fix `README.md`.

---
## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Diagram](#2-architecture-diagram)
3. [Infrastructure & Virtualization](#3-infrastructure--virtualization)
4. [Container & Runtime Configuration](#4-container--runtime-configuration)
5. [The A2A Express Bridge (`index.js`)](#5-the-a2a-express-bridge-indexjs)
6. [Agent Discovery — Apicurio Registry](#6-agent-discovery--apicurio-registry)
7. [State Management & Routing](#7-state-management--routing)
8. [The Cognitive Engine (Prompt Architecture)](#8-the-cognitive-engine-prompt-architecture)
9. [Fleet Inventory](#9-fleet-inventory)
10. [Operational Notes](#10-operational-notes)
11. [Known Constraints & Workarounds](#11-known-constraints--workarounds)

---

## 1. Overview

This repository implements a **centralized Agent-to-Agent (A2A) network** in which multiple OpenClaw-powered agent containers communicate over a shared Docker bridge network using JSON-RPC 2.0 payloads. Each container runs two processes managed by PM2:

1. **A2A Express Bridge** (`index.js`) — an HTTP server that receives JSON-RPC task requests, routes them to the local OpenClaw root agent over the Gateway WebSocket, and returns structured JSON responses.
2. **OpenClaw Gateway** — the OpenClaw runtime that runs the agent's cognitive loop and tool execution.

An **Apicurio Registry** container serves as a lightweight service-discovery layer: each agent registers an **Agent Card** (metadata describing its role, protocols, and endpoint) on startup, allowing other agents or external clients to discover and address peers dynamically.

The fleet currently consists of two specialized agents — **Researcher** and **Coder** — each sharing the same Docker image but customized through environment variables and isolated `.openclaw` state directories.

> **Operating mode — single-agent-per-container (#9, #11).** Each container runs **one working agent** (`main`) that does the task itself using full tool access. The original **tri-node** design (planner → executor → reviewer sub-agents, with the Researcher's reviewer delegating code to the Coder over A2A) is **parked** as future work pending an OpenClaw fix: OpenClaw sub-agents cannot reliably drive cross-agent A2A calls, and the prompt-level delegation directive was overridden by the model's task-completion instinct. The tri-node artifacts are **preserved, not deleted** — sub-agent entries are commented out in `openclaw.json` (JSON5), the orchestrator prompts are saved as `IDENTITY.tri-node.md`, the sub-agent directories are untouched, and git tag `v0.1.0` (commit `5e428c0`) is the revival baseline. Cross-agent A2A **does** work in single-agent mode: the Researcher's `main` curls the Coder's bridge directly when a task needs code (see §8). See §8 for the parked design and revival path, and §11 for the constraint that parked it.

---

## 2. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        macOS Host                                │
│                                                                 │
│   ~/GC/openclaw-a2a-bridge/                                     │
│   ├── Dockerfile                                                │
│   ├── ecosystem.config.js                                       │
│   ├── index.js                                                  │
│   ├── podman-compose.yml                                        │
│   ├── vm-bridge.sh          (tmux bridge helper)                │
│   ├── AGENTS.md                                                 │
│   └── agents/                                                   │
│       ├── researcher/.openclaw/  (main; planner/executor/        │
│       │                          reviewer PARKED, see §8)       │
│       └── coder/.openclaw/      (main; planner/executor/        │
│                                    reviewer PARKED, see §8)     │
│                                                                 │
│         │  VirtioFS mount → /mnt/workspace on the VM            │
│         ▼                                                       │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │              Fedora VM (Tart: poc-openclaw-01)               │ │
│ │                   SELinux: Permissive                        │ │
│ │                                                              │ │
│ │  ┌──────────────────────────────────────────────────────┐   │ │
│ │  │           Podman (openclaw-net bridge)                │   │ │
│ │  │                                                       │   │ │
│ │  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐ │   │ │
│ │  │  │   Apicurio   │  │  Researcher  │  │    Coder     │ │   │ │
│ │  │  │  Registry    │  │   Container  │  │  Container   │ │   │ │
│ │  │  │  :8080       │  │              │  │              │ │   │ │
│ │  │  │              │  │ ┌──────────┐ │  │ ┌──────────┐ │ │   │ │
│ │  │  │  Agent Card  │  │ │   PM2    │ │  │ │   PM2    │ │ │   │ │
│ │  │  │  Registry    │  │ │ ┌──────┐ │ │  │ │ ┌──────┐ │ │ │   │ │
│ │  │  │              │  │ │ │Bridge │ │ │  │ │ │Bridge │ │ │   │ │
│ │  │  └──────────────┘  │ │ │ :3000 │ │ │  │ │ │ :3000 │ │ │   │ │
│ │  │                    │ │ └──────┘ │ │  │ │ └──────┘ │ │   │ │
│ │  │                    │ │ ┌──────┐ │ │  │ │ ┌──────┐ │ │   │ │
│ │  │                    │ │ │Gate- │ │ │  │ │ │Gate- │ │ │   │ │
│ │  │                    │ │ │way   │ │ │  │ │ │way   │ │ │   │ │
│ │  │                    │ │ └──────┘ │ │  │ │ └──────┘ │ │   │ │
│ │  │                    │ └──────────┘ │  │ └──────────┘ │ │   │ │
│ │  │                    └──────────────┘  └─────────────┘ │   │ │
│ │  └──────────────────────────────────────────────────────┘   │ │
│ └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Request Flow (Single Agent)

```
External Client / Peer Agent
    │
    │  POST /a2a/tasks  (JSON-RPC 2.0)
    ▼
┌───────────────────────────────────────────────────┐
│   A2A Express Bridge (index.js, port 3000)         │
│                                                    │
│  1. Parse JSON-RPC payload                         │
│  2. Extract task instruction                       │
│  3. Open WebSocket to the in-container Gateway     │
│     (ws://127.0.0.1:18789, token auth)             │
│  4. Gateway WS lifecycle (NOT the fire-and-forget  │
│     CLI — see §5 for why):                          │
│       a. `connect` (challenge-first, signed)        │
│            -> hello-ok                             │
│       b. `agent`               -> { runId }        │
│       c. subscribe to `chat` events for            │
│            sessionKey=agent:main:main; wait for    │
│            the final synthesized assistant         │
│            message.                                │
│       d. `agent.wait` is raced in parallel for     │
│            early error detection. In single-agent  │
│            mode there is no sessions_yield, so     │
│            agent.wait resolves at run completion    │
│            (not at the first yield, as in tri-node).│
│  5. Wrap synthesized result in JSON-RPC envelope    │
└───────────┬───────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────────────────┐
│   OpenClaw Gateway (PM2 → npx openclaw gateway run) │
│   WS server on 127.0.0.1:18789 (token auth)         │
│                                                    │
│   Root Agent (main) — single-agent mode (#9):       │
│     main does the task ITSELF using full tool       │
│     access (exec, web_fetch, read/write/edit).      │
│     No sessions_spawn / sessions_yield; no spawn   │
│     tree. On the Researcher, main curls the Coder   │
│     bridge directly when a task needs code (§8).    │
│                                                    │
│   [PARKED — tri-node: planner/executor/reviewer     │
│    sub-agents via sessions_spawn. See §8 + tag      │
│    v0.1.0 for the revival path.]                    │
└───────────────────────────────────────────────────┘
```

---

## 3. Infrastructure & Virtualization

### Host Environment

| Layer | Technology | Details |
|-------|-----------|---------|
| **Physical host** | macOS | Runs Tart hypervisor |
| **Virtual machine** | Fedora (via Tart) | VM name: `poc-openclaw-01` |
| **Container engine** | Podman + podman-compose | Rootless containers on Fedora |
| **Network** | `openclaw-net` bridge | Shared internal bridge network for all services |

### File Sharing (VirtioFS)

The local macOS workspace at `~/GC/openclaw-a2a-bridge` is mounted into the Fedora VM via **VirtioFS** at `/mnt/workspace` (configured via the Tart `--dir` flag: `--dir ~/GC/openclaw-a2a-bridge:tag=workspace`). Podman then bind-mounts this directory into each container at `/app`:

```yaml
# podman-compose.yml (per-service)
volumes:
  - .:/app
```

This means any change to agent configuration files (`.openclaw/` directories, prompt files, etc.) on the macOS host is immediately reflected inside the running containers without rebuilding the image. Scripts written on the macOS host are also directly executable on the VM at `/mnt/workspace/<script>.sh` — no `scp` needed.

### SELinux Configuration

The Fedora VM's SELinux is set to **Permissive** globally. This is a deliberate decision to cleanly bypass VirtioFS and container labeling conflicts that would otherwise block Podman from accessing the mounted volumes. In permissive mode, SELinux logs denials but does not enforce them, allowing uninterrupted volume access during development.

> **Production note:** In a production deployment, SELinux should be returned to `Enforcing` with proper volume labels (`:Z` or `:z` suffixes on Podman bind mounts) rather than running permissive globally.

---

## 4. Container & Runtime Configuration

### Dockerfile

```dockerfile
FROM node:24-trixie-slim

RUN apt update && apt install -y curl jq

# Install OpenClaw, PM2, and Express globally
RUN npm install -g openclaw@latest pm2@latest express@latest

# Tell Node.js where to find global modules so index.js can require('express')
ENV NODE_PATH=/usr/local/lib/node_modules

WORKDIR /app

# PM2 runtime keeps the container alive and monitors the apps
CMD ["pm2-runtime", "ecosystem.config.js"]
```

#### Key Decisions

| Decision | Rationale |
|----------|-----------|
| **Global npm installs** (`npm install -g`) | The VirtioFS mount bind-mounts the macOS workspace at `/app`. If `node_modules` were installed locally inside `/app`, the VirtioFS mount would overwrite or shadow them. Installing globally (`/usr/local/lib/node_modules`) keeps dependencies outside the mount path. |
| **`NODE_PATH` env var** | Node.js does not search global `node_modules` by default. Setting `NODE_PATH=/usr/local/lib/node_modules` allows `index.js` to `require('express')` without a local `node_modules` directory. |
| **`curl` and `jq`** | Included for debugging and ad-hoc HTTP testing inside containers. |
| **`node:24-trixie-slim`** | Minimal Node.js 24 image on Debian Trixie — small footprint, latest runtime. |
| **`pm2-runtime` as CMD** | PM2 acts as PID 1, managing both the Express bridge and the OpenClaw gateway, handling restarts, and keeping the container alive. |

### PM2 Ecosystem (`ecosystem.config.js`)

```javascript
module.exports = {
  apps: [
    {
      name: "openclaw-gateway",
      script: "npx",
      args: "openclaw gateway run",
      autorestart: true,
      watch: false
    },
    {
      name: "a2a-bridge",
      script: "index.js",
      autorestart: true,
      watch: true,
      env: {
        NODE_ENV: "development",
      }
    }
  ]
};
```

PM2 manages **two simultaneous processes** in each container:

| PM2 App | Script | Purpose | Watch | Auto-restart |
|---------|--------|---------|-------|-------------|
| `openclaw-gateway` | `npx openclaw gateway run` | Runs the OpenClaw gateway (agent runtime) | `false` | `true` |
| `a2a-bridge` | `index.js` | Express HTTP server receiving A2A JSON-RPC payloads | `true` (auto-restarts on file changes) | `true` |

#### The `npx` Workaround for the OpenClaw Gateway

The OpenClaw gateway is launched via `script: "npx", args: "openclaw gateway run"` rather than `script: "openclaw", args: "gateway run"`. This works around a known PM2 bug where PM2 strips arguments when invoking globally-installed binaries directly. By routing through `npx`, PM2 invokes the `npx` binary (which it can find and execute correctly), and `npx` in turn resolves and launches `openclaw gateway run` with its arguments intact.

---

## 5. The A2A Express Bridge (`index.js`)

The Express bridge is the network-facing component of each agent container. It exposes two HTTP endpoints and handles the full request lifecycle: payload ingestion → OpenClaw Gateway WS call → JSON-RPC response.

### Why the bridge speaks the Gateway WebSocket, not the CLI

> **Single-agent mode note (#9, #11):** In the current operating mode there is **no spawn tree** — `main` does the task itself and never calls `sessions_yield`. The WS lifecycle below is therefore simpler in practice: `agent.wait` resolves at **run completion** (not at a first yield), and the final `chat` event arrives on the **same runId** (not a resumed one). The tri-node rationale and the "resumed runId" semantics are preserved below as the **historical/future** rationale — they describe the behavior the bridge was originally built to handle and will apply again if the tri-node is revived (see §8). The bridge code is unchanged; only the runtime behavior differs.

The original bridge shelled out to the OpenClaw CLI:

```bash
openclaw agent --agent main --message "<task>" --json
```

This **silently broke sub-agent delegation**. Per `docs/concepts/concepts/agent-loop.md`, the `agent` entry point (both the RPC method and the `openclaw agent` CLI wrapper) returns `{ runId, acceptedAt }` **immediately at acceptance** — it does **not** wait for the run to complete. The `main` agent delegates to `planner`/`executor`/`reviewer` via `sessions_spawn`, which is explicitly **non-blocking** (returns a `runId` + `childSessionKey` right away, per `docs/concepts/concepts/session-tool.md`); `main` then calls `sessions_yield` to end its turn and wait for the follow-up completion event.

Because the CLI process returns at acceptance, the bridge received the acceptance envelope, returned it to the A2A caller, and **closed the connection before the sub-agent tree finished**. The sub-agent responses were produced in a session the bridge was no longer watching — so the A2A caller never saw them.

The fix is to use the documented Gateway WebSocket lifecycle, which separates **acceptance** from **completion**:

| Step | WS method / event | Returns | Semantics |
|------|-------------------|---------|-----------|
| 1 | `connect` (challenge-first, device-signed) | `hello-ok` | Handshake + token auth |
| 2 | `agent` | `{ runId, acceptedAt }` | Accept the run (fire-and-forget) |
| 3 | `chat` events (subscribed) | final assistant message | **Wait for the main session's final synthesized `chat` event** (`sessionKey=agent:main:main`, `state=final`, `role=assistant`). In tri-node mode this arrives under a **resumed runId** (new turn) AFTER the whole spawn tree finishes; in single-agent mode it arrives on the **same runId** when `main` completes. |
| 4 | `agent.wait` (raced, error-only) | `{ status, startedAt, endedAt, error? }` | Resolves at the **first `sessions_yield`** (lifecycle end of the ORIGINAL runId) — NOT at spawn-tree completion. Used only to surface early errors; its resolution is NOT treated as completion. **In single-agent mode there is no `sessions_yield`, so `agent.wait` resolves at run completion** — but it is still raced only for early-error detection; the `chat` event remains the source of truth. |

> ⚠️ **`agent.wait` does NOT block until the spawn tree finishes (tri-node mode).** It resolves at the first `sessions_yield`, which ends the original runId's turn. Sub-agents (planner → executor → reviewer) keep running in the background; the main session's final synthesized message arrives later under a **resumed runId** (new turn). The bridge therefore waits for the main session's final `chat` event, not for `agent.wait`.
>
> **In single-agent mode (#9)** there is no `sessions_yield` and no spawn tree, so `agent.wait` resolves at run completion and the final `chat` event arrives on the same runId. The bridge still treats the `chat` event as the source of truth and uses `agent.wait` only to surface early errors.

> ⚠️ **`sessions.history` is NOT used.** It requires the `operator.admin` scope; the device is approved for `operator.write` only, so `sessions.history` triggers `PAIRING_REQUIRED`. The result is read from the `chat` event stream instead.

The bridge overrides the default 30s wait with `RUN_TIMEOUT_MS` (default 600000ms = 10min) to accommodate long sub-agent chains. `agent.wait` is wait-only — it does not stop the run on timeout.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `AGENT_PORT` | `3000` | HTTP listen port for the Express server |
| `AGENT_ROLE` | `"Agent"` | Human-readable role name (e.g., `"Researcher"`, `"Coder"`) — used in logs, Agent Card, and responses |
| `REGISTRY_URL` | `http://apicurio:8080/apis/registry/v2` | Apicurio Registry base URL for agent card registration |
| `HOST_IP` | `localhost` | Container hostname or IP used in the Agent Card endpoint field |
| `OPENCLAW_STATE_DIR` | *(set per-service in Compose)* | Isolated `.openclaw` directory path for agent memory/config |
| `GATEWAY_WS_URL` | `ws://127.0.0.1:18789` | In-container OpenClaw Gateway WebSocket endpoint |
| `GATEWAY_AUTH_TOKEN` | *(set per-service in Compose)* | Shared-secret token matching `gateway.auth.token` in the agent's `openclaw.json` |
| `OPENCLAW_AGENT_ID` | `main` | Target agent id for the `agent` call |
| `OPENCLAW_SESSION_KEY` | `main` | Session key to run the task in and read history from |
| `RUN_TIMEOUT_MS` | `600000` | Max wait for the main session's final `chat` event (and `agent.wait` race) in ms |

### Endpoints

#### `GET /.well-known/agent.json` — Agent Card Discovery

Returns the agent's public metadata card, allowing other agents and clients to discover its capabilities:

```json
{
  "name": "Researcher",
  "version": "1.0.0",
  "description": "Specialized OpenClaw node acting as Researcher",
  "protocols": ["A2A", "JSON-RPC 2.0"],
  "endpoint": "http://researcher:3000/a2a/tasks"
}
```

This follows the A2A protocol convention of serving agent metadata at the well-known path.

#### `POST /a2a/tasks` — Task Execution

Accepts a JSON-RPC 2.0 payload and routes the task to the local OpenClaw root agent over the Gateway WebSocket.

**Request format:**

```json
{
  "jsonrpc": "2.0",
  "method": "task",
  "params": {
    "task": "Research the latest trends in quantum computing"
  },
  "id": "req-001"
}
```

**Internal flow:**

1. The bridge extracts `payload.params.task` (falling back to `"status"` if absent).
2. It opens a WebSocket to `GATEWAY_WS_URL` and performs the `connect` handshake with `GATEWAY_AUTH_TOKEN`.
3. It sends an `agent` request with `{ agentId, sessionKey, message, idempotencyKey }` and captures `runId`.
4. It subscribes to `chat` events for `sessionKey=agent:main:main` and waits for the final synthesized assistant message. In parallel, it races `agent.wait` with `{ runId, timeoutMs: RUN_TIMEOUT_MS }` **for early error detection only** — `agent.wait` resolves at the first `sessions_yield` (NOT at spawn-tree completion), so its resolution is not treated as completion; only an error on `agent.wait` is surfaced. In single-agent mode (#9) there is no `sessions_yield`, so `agent.wait` resolves at run completion and the final `chat` event arrives on the same runId; in tri-node mode the main session's final synthesized message arrives later under a resumed runId (new turn) after the whole spawn tree (planner → executor → reviewer) finishes.
5. The final assistant content (captured from the `chat` event stream, with fallbacks to concatenated deltas and `lastFinalText` when the final event has `hasMsg=false`) is collapsed to a string and parsed as JSON when possible (falling back to the raw string), then wrapped in a JSON-RPC 2.0 response envelope.

**Success response:**

```json
{
  "jsonrpc": "2.0",
  "result": {
    "status": "success",
    "agent": "Researcher",
    "output": { /* parsed JSON from the reviewer's final message, or raw string */ },
    "runId": "<uuid>",
    "runStatus": "ok"
  },
  "id": "req-001"
}
```

**Error response (HTTP 500):**

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32603,
    "message": "Agent run errored: ..."
  }
}
```

Error code `-32603` is the JSON-RPC 2.0 standard code for "Internal error." A `runStatus` of `"timeout"` means the main session's final `chat` event did not arrive within `RUN_TIMEOUT_MS` (the run keeps going in the gateway); the bridge surfaces this as an error so the A2A caller knows the response was not captured. A `runStatus` of `"error"` means `agent.wait` reported a lifecycle error for the run.

### Startup Behavior

On `app.listen()`, the bridge waits 5 seconds (to allow the Apicurio Registry to become healthy) and then registers its Agent Card with the registry. See [§6 Agent Discovery](#6-agent-discovery--apicurio-registry) for details.

---

## 6. Agent Discovery — Apicurio Registry

A critical component not immediately visible in the agent containers themselves is the **Apicurio Registry** — an in-memory schema/artifact registry that serves as the network's service-discovery layer.

### Compose Definition

```yaml
apicurio:
  image: quay.io/apicurio/apicurio-registry-mem:2.4.14.Final
  ports:
    - "8080:8080"
  networks:
    - openclaw-net
```

### Registration Flow

When each agent's Express bridge starts, it performs the following after a 5-second delay:

```javascript
const response = await fetch(`${REGISTRY_URL}/groups/default/artifacts`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Registry-ArtifactId': ROLE,
    'X-Registry-ArtifactType': 'JSON'
  },
  body: JSON.stringify(agentCard)
});
```

| Step | Behavior |
|------|----------|
| **Success (200)** | Agent Card registered. Logged: `Successfully registered with Apicurio!` |
| **Conflict (409)** | Agent Card already exists from a previous registration. Logged: `Agent Card already exists.` |
| **Other error** | Logged: `Failed to register. Status: <code>` |
| **Network error** | Logged: `Error reaching Apicurio: <message>` |

### Purpose

The registry allows:
- **Dynamic discovery:** Any agent or external client can query Apicurio to find all registered agents, their roles, endpoints, and supported protocols.
- **Decoupling:** Agents don't need hardcoded peer addresses — they look up the registry instead.
- **Extensibility:** New agents can join the network by simply starting up and registering; no compose file changes needed for discovery (only for deployment).

> **Note:** The Apicurio image used (`apicurio-registry-mem`) stores data in memory. Agent registrations are lost on container restart, but the 5-second delayed re-registration on bridge startup handles this automatically.

---

## 7. State Management & Routing

### State Isolation

Each agent container operates with its own isolated OpenClaw state directory, controlled by the `OPENCLAW_STATE_DIR` environment variable. This ensures agent memory, conversation history, sub-agent registrations, and prompt configurations never bleed between agents.

```yaml
# researcher service
environment:
  - OPENCLAW_STATE_DIR=/app/agents/researcher/.openclaw

# coder service
environment:
  - OPENCLAW_STATE_DIR=/app/agents/coder/.openclaw
```

Because the workspace is bind-mounted at `/app`, these paths map to the following directories on the macOS host:

```
~/poc/openclaw-workspace/
├── agents/
│   ├── researcher/
│   │   └── .openclaw/     ← researcher state (main, planner, executor, reviewer)
│   └── coder/
│       └── .openclaw/     ← coder state (main, planner, executor, reviewer)
```

### Payload Routing

The bridge communicates with the OpenClaw Gateway over the **Gateway WebSocket** (`ws://127.0.0.1:18789`), not by shelling out to the CLI. The CLI path (`openclaw agent`) is fire-and-forget — it returns at acceptance, not completion — which silently dropped sub-agent responses (see [§5](#5-the-a2a-express-bridge-indexjs) for the full rationale).

The bridge uses the documented WS lifecycle:

| WS method / event | Purpose |
|-------------------|---------|
| `connect` (challenge-first, device-signed) | Handshake + token auth (`GATEWAY_AUTH_TOKEN`) |
| `agent` | Accept the run on `agentId`/`sessionKey`, get `runId` |
| `chat` events (subscribed) | Wait for the main session's final synthesized assistant message (`sessionKey=agent:main:main`, `state=final`) — in tri-node mode arrives under a resumed runId after the spawn tree finishes; in single-agent mode (#9) arrives on the same runId when `main` completes |
| `agent.wait` (raced, error-only) | Resolves at the first `sessions_yield` (NOT spawn-tree completion); used only to surface early errors. In single-agent mode there is no `sessions_yield`, so it resolves at run completion — still raced only for early-error detection |

The WebSocket connection inherits the container's environment, and `OPENCLAW_STATE_DIR` points the in-container Gateway at the correct isolated agent's state directory. The `agentId` (`main`) and `sessionKey` (`main`) target the root agent registered in that state directory.

### Network Topology

All three services (`apicurio`, `researcher`, `coder`) are connected to the `openclaw-net` bridge network. Within this network, services address each other by service name:

```
researcher → http://coder:3000/a2a/tasks
coder      → http://researcher:3000/a2a/tasks
any        → http://apicurio:8080/apis/registry/v2
```

Both `researcher` and `coder` declare `depends_on: apicurio`, ensuring the registry starts first (though the 5-second delay in `index.js` provides the actual health-readiness buffer).

---

## 8. The Cognitive Engine (Prompt Architecture)

### Headless-Only Constraint

All agents operate **strictly as headless nodes**. Conversational filler, pleasantries, and natural-language preambles are explicitly forbidden. This is a hard architectural constraint, not a style preference: because agent output is parsed as JSON by the Express bridge, any non-JSON text in the response (e.g., "Sure, here's your research:") would corrupt the JSON-RPC payload and break the A2A protocol contract.

Agent prompt files (`USER.md`, `IDENTITY.md`) enforce this by instructing the agent that it is communicating exclusively with an automated Node.js bridge that expects deterministic, raw data outputs.

### The Root Agent (`main`)

Each agent container has a root agent named `main` registered in its isolated `.openclaw` state directory. The root agent is defined by two prompt files:

#### `USER.md`

Instructs the agent that:
- It is talking to an **automated Node.js A2A bridge**, not a human.
- It must produce **deterministic, raw data outputs** (valid JSON or structured text).
- Conversational filler is forbidden.
- Responses must be parseable by `JSON.parse()`.

#### `IDENTITY.md`

Defines the agent's **domain persona**. In single-agent mode (#9):
- **Researcher:** Does the research work itself using full tool access. When a task requires code, `main` curls the Coder's bridge directly over A2A (see "A2A Code Delegation" below) and folds the Coder's `result.output` into its final deliverable. It never writes code itself.
- **Coder:** Does the coding work itself using full tool access. It receives a code-generation spec (from the Researcher over A2A, or a direct request from an external client), produces the code, and returns it as a structured JSON deliverable. It is a leaf node — it never calls back to the Researcher.

> **Tri-node (PARKED):** The original `IDENTITY.md` described `main` as an orchestrator-only router that delegates through the planner → executor → reviewer loop. That prompt is preserved as `IDENTITY.tri-node.md` (see "The Standardized Sub-Agent Loop" below for the parked design and revival path).

### The Standardized Sub-Agent Loop (PARKED — future design pending an OpenClaw fix)

> ⚠️ **Status — PARKED (#9, #11).** The tri-node sub-agent loop (planner → executor → reviewer) is the **intended architecture**, preserved here as the future design. It is **not currently active**. It is parked because of an OpenClaw platform limitation: OpenClaw sub-agents cannot reliably drive cross-agent A2A calls, and the prompt-level delegation directive (Researcher's reviewer → Coder) was overridden by the model's task-completion instinct — the reviewer wrote the code itself and the Coder's bridge never received a delegation (proven across 4 end-to-end tests, 2026-08-01). See §11 for the constraint row.
>
> **Current mode — single-agent-per-container:** `main` does the task itself using full tool access. On the Researcher, `main` curls the Coder's bridge directly when a task needs code (see "A2A Code Delegation" below). There is no `sessions_spawn` / `sessions_yield` and no spawn tree.
>
> **Revival path (when the OpenClaw fix lands):**
> 1. In each agent's `openclaw.json` (JSON5), **uncomment** the `planner` / `executor` / `reviewer` entries in `agents.list`, and **uncomment** `main`'s `deny` list + `alsoAllow` (`sessions_spawn`, `sessions_yield`, `subagents`) so `main` becomes an orchestrator-only router again.
> 2. **Swap** `IDENTITY.tri-node.md` back to `IDENTITY.md` (the single-agent `IDENTITY.md` is preserved in git history / on the branch).
> 3. The sub-agent directories (`agents/{researcher,coder}/.openclaw/agents/{planner,executor,reviewer}/` and `workspace/{planner,executor,reviewer}/`) are **untouched** — no re-creation needed.
> 4. **Baseline:** git tag `v0.1.0` (commit `5e428c0`) is the revival baseline; the tri-node artifacts were preserved in commit `717b2cd` (issue #9). See issues #6 (umbrella), #7 (plugin/extend OpenClaw), #8 (fork/build a new runtime) for the structural-enforcement options under evaluation.
>
> The description below is the **parked design** — the architecture the bridge was built to handle and will apply again once revived.

Every root agent contains the **exact same tri-node architecture** — three sub-agents registered in the agent's `.openclaw` directory. The architecture is identical across all agents; only the `IDENTITY.md` customization (Research vs. Coding domain) differs.

```
┌─────────────────────────────────────────────┐
│              Root Agent (main)               │
│                                             │
│  Receives task from A2A Bridge              │
│  Delegates through three-node loop:         │
│                                             │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐ │
│  │ Planner  │──▶│ Executor │──▶│ Reviewer │ │
│  └──────────┘   └──────────┘   └──────────┘ │
│                                             │
│  Returns synthesized result to bridge       │
└─────────────────────────────────────────────┘
```

#### Node 1: `planner`

| Aspect | Detail |
|--------|--------|
| **Role** | Analyzes the incoming task and produces a strict, step-by-step sequential blueprint or search strategy. |
| **Does NOT execute** | The planner only thinks and plans. It does not run tools, write files, or make requests. |
| **Output** | A structured plan (steps, search queries, code outline, etc.) passed to the executor. |

#### Node 2: `executor`

| Aspect | Detail |
|--------|--------|
| **Role** | Executes the planner's blueprint using system tools. |
| **Capabilities** | Writes scripts, scrapes the web, runs commands, creates files, etc. |
| **Output** | Raw data, code, research findings, or generated artifacts passed to the reviewer. |

#### Node 3: `reviewer`

| Aspect | Detail |
|--------|--------|
| **Role** | Audits the executor's output for accuracy, formatting constraints, security, and hallucinations. |
| **Quality gates** | Verifies factual claims, checks code correctness, ensures JSON compliance, strips any conversational filler. |
| **Output** | The final, pristine deliverable — synthesized and formatted for JSON-RPC response back to the network. |

> **Researcher reviewer — A2A code delegation (PARKED with the tri-node design):**
> In the parked tri-node design, the Researcher's `reviewer/IDENTITY.md` carries an **"A2A Code Delegation"** directive: when the task requires generating or modifying code, the reviewer is instructed to POST a precise code spec to the Coder agent at `http://coder:3000/a2a/tasks` (JSON-RPC) and fold the Coder's `result.output` into its synthesized deliverable, rather than writing the code itself. The delegation is **one-way** (Coder never calls back to Researcher) and **code-only** (research/synthesis stays the reviewer's job).
>
> ⚠️ **Status — PARKED (agent-platform limitation, #9/#11):** End-to-end testing (2026-08-01) showed this directive does **not** fire in practice. The reviewer is a capable model with `tools.profile: "full"` (exec/curl access), and its task-completion instinct overrides the prompt-level "FORBIDDEN FROM WRITING CODE" rule — it generates the code itself and Coder's bridge never receives a delegation. This is tracked as an **agent-platform limitation**, not a model limitation (other non-OpenClaw agents perform sub-agent delegation reliably). See §11 and issues #6/#7/#8 for the structural-enforcement options under evaluation.
>
> ✅ **Single-agent mode — A2A delegation DOES fire (#10):** In the current single-agent mode, the Researcher's `main` (not the reviewer) curls the Coder's bridge directly when a task needs code. Live testing (2026-08-11) confirmed the Coder receives the payload and generates the code — the cross-agent A2A call works end-to-end. The residual issues are output-formatting hygiene (narration prefixes, markdown fences), not delegation failure. See §11.

### Orchestrator Guardrails (Researcher `main`) — PARKED with the tri-node design

> ⚠️ **Status — PARKED (#9, #11).** These guardrails apply to the tri-node orchestrator prompt (`IDENTITY.tri-node.md`), which is **not currently active**. In single-agent mode, `main` does the task itself — there is no spawn loop to terminate early, so these failure modes do not arise. The guardrails are preserved here with the parked design and will apply again when the tri-node is revived (see the revival path above).

The Researcher root agent (`main/IDENTITY.tri-node.md`) carries three guardrails that fix recurring early-termination failure modes discovered during end-to-end testing. Without them, the orchestrator tended to end its turn mid-loop, capturing narration as the final answer and orphaning the reviewer.

| Guardrail | Failure mode it fixes |
|----------|----------------------|
| **TRUNCATED-OUTPUT RULE** | Orchestrator must not retrieve, narrate, or repair truncated executor output; it forwards the resume payload straight to the reviewer. |
| **STEP 5→6 ATOMIC** | `sessions_spawn(reviewer)` and `sessions_yield` must happen back-to-back in the same turn (fixes the reviewer being orphaned when the orchestrator ends after spawning it). |
| **EXECUTOR ERROR / EMPTY-OUTPUT RULE** | On executor error or empty output, do not re-spawn the executor; proceed immediately to the reviewer with the blueprint plus a factual failure note. There is no "STEP 4b: retry executor" step. |

### Domain Customization (PARKED with the tri-node design)

The tri-node architecture is identical, but each agent's `IDENTITY.md` customizes the domain. In single-agent mode, the same domain split applies to `main` directly (Researcher researches, Coder codes) — see the `IDENTITY.md` files for the single-agent personas.

| Agent | Planner Focus | Executor Tools | Reviewer Focus |
|-------|--------------|----------------|----------------|
| **Researcher** | Search strategy, query formulation, source prioritization | Web scraping, API calls, data collection | Fact-checking, source credibility, citation completeness |
| **Coder** | Code architecture, implementation steps, test plan | Code generation, file creation, script execution | Code correctness, security review, syntax validation |

---

## 9. Fleet Inventory

### Currently Deployed Services

| Service | Image | Role | Port | State Directory | Networks |
|---------|-------|------|------|-----------------|----------|
| `apicurio` | `quay.io/apicurio/apicurio-registry-mem:2.4.14.Final` | Agent Card Registry | `8080:8080` | N/A (in-memory) | `openclaw-net` |
| `researcher` | Built from `Dockerfile` | Research agent | `3000` (internal) | `/app/agents/researcher/.openclaw` | `openclaw-net` |
| `coder` | Built from `Dockerfile` | Coding agent | `3000` (internal) | `/app/agents/coder/.openclaw` | `openclaw-net` |

### Agent Sub-Nodes (per agent)

Each agent container (`researcher`, `coder`) contains these sub-agents in its `.openclaw` state directory. In single-agent mode (#9), only `main` is **active**; the tri-node sub-agents are **commented out** in `openclaw.json` (JSON5) and preserved for the revival path (see §8). The table below reflects the **current** state:

| Sub-Agent | Node Type | Tools | Function |
|-----------|-----------|-------|----------|
| `main` | Root (active) | `tools.profile: "full"` (no deny list) | **Working agent** — receives A2A bridge payloads and does the task itself using full tool access (exec, web_fetch, read/write/edit). On the Researcher, curls the Coder's bridge directly when a task needs code (§8). |
| `planner` | Sub-agent (PARKED) | `tools.profile: "full"` | Commented out in `openclaw.json`. Would analyze task, produce sequential blueprint (does not execute). |
| `executor` | Sub-agent (PARKED) | `tools.profile: "full"` (no deny list) | Commented out in `openclaw.json`. Would execute planner's blueprint using system tools (exec, curl, web_fetch, file I/O). |
| `reviewer` | Sub-agent (PARKED) | `tools.profile: "full"` (no deny list) | Commented out in `openclaw.json`. Would audit output, synthesize final deliverable; on the Researcher, carries the (parked) A2A code-delegation directive. |

> **Coder parity (Phase 1):** Both agents share the same single-agent architecture: `main` is the working agent with full tool access; the tri-node sub-agents are commented out identically. The planner `id` is lowercase (`planner`) to match the `sessions_spawn` casing requirement (relevant when the tri-node is revived).

---

## 10. Operational Notes

### The tmux Bridge (required for agent-terminal access to the VM)

> ⚠️ **Read this first.** The VS Code agent terminal cannot reach the VM's local subnet (see §11, "VS Code agent terminal cannot reach the VM's local subnet"). All commands below that target the VM or the containers must go through the **tmux bridge** — a tmux server started from an interactive Terminal.app shell, which runs in a working network context.

The helper script **`vm-bridge.sh`** (in the workspace root) automates the bridge. It must be started from an **interactive Terminal.app shell** (not the VS Code terminal), because the tmux server inherits the network context of the shell that launches it.

```bash
# From an interactive Terminal.app shell (NOT the VS Code terminal):

# Start the VM (if not already running)
poc-openclaw-01   # alias: tart run poc-openclaw-01 --no-graphics --dir ~/GC/openclaw-a2a-bridge:tag=workspace &

# Start the tmux bridge (idempotent — safe to re-run)
./vm-bridge.sh start

# Check bridge + VM + fleet status
./vm-bridge.sh status

# Run a command on the VM via the bridge (prints output when done)
./vm-bridge.sh run 'sudo podman ps'

# Stop the tmux bridge (does NOT stop the VM)
./vm-bridge.sh stop
```

Once the bridge is up, the **VS Code agent terminal** can run commands on the VM by calling `vm-bridge.sh run "<cmd>"`. The script sends the command into the tmux pane via `tmux send-keys`, waits for completion, and prints the captured output. Commands execute as `admin` on the VM over SSH.

> **Why the bridge is needed:** the agent terminal's `ssh admin@192.168.64.3` fails with `No route to host`, but the same command inside the tmux session (started from Terminal.app) succeeds. The tmux server bridges the two network contexts.

> **Workspace on the VM:** the macOS workspace is mounted at `/mnt/workspace` on the VM. Scripts written on the macOS host are immediately executable on the VM at that path — no `scp` needed.

### Build & Start the Fleet

From the **agent terminal** (via the bridge), or from an interactive shell that can reach the VM:

```bash
# Via the bridge (agent terminal)
./vm-bridge.sh run 'cd /mnt/workspace && sudo podman-compose -f podman-compose.yml up -d --build'

# Or directly on the VM (interactive shell / SSH)
cd /mnt/workspace && sudo podman-compose -f podman-compose.yml up -d --build
```

```bash
# View running containers (via the bridge)
./vm-bridge.sh run 'sudo podman ps'

# View logs for a specific service (via the bridge)
./vm-bridge.sh run 'sudo podman logs researcher | tail -40'

# View PM2 process status inside a container (via the bridge)
./vm-bridge.sh run 'sudo podman exec workspace_researcher_1 pm2 status'
```

### Stop the Fleet

```bash
# Via the bridge (agent terminal)
./vm-bridge.sh run 'cd /mnt/workspace && sudo podman-compose -f podman-compose.yml down'

# Or directly on the VM
cd /mnt/workspace && sudo podman-compose -f podman-compose.yml down
```

### Send a Test Payload

The agent containers don't expose host ports, so test payloads are sent from **inside the network** via `sudo podman exec`:

```bash
# Via the bridge (agent terminal) — query the Researcher from inside the Coder container
./vm-bridge.sh run 'sudo podman exec workspace_coder_1 curl -s http://researcher:3000/a2a/tasks \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"task\",\"params\":{\"task\":\"hello\"},\"id\":\"1\"}"'

# Discover an agent's card (from inside the network)
./vm-bridge.sh run 'sudo podman exec workspace_researcher_1 curl -s http://coder:3000/.well-known/agent.json'

# List all registered agents in Apicurio (from inside the network)
./vm-bridge.sh run 'sudo podman exec workspace_researcher_1 curl -s http://apicurio:8080/apis/registry/v2/groups/default/artifacts'
```

> **Note on ports:** Both `researcher` and `coder` listen on port `3000` internally, but neither exposes a host port mapping in the current compose file. To send requests from the macOS host directly, add `ports: ["3001:3000"]` / `ports: ["3002:3000"]` to the compose file.

### Inspect Agent State

```bash
# On the macOS host (the .openclaw directories are in the workspace)
ls -la agents/researcher/.openclaw/
ls -la agents/coder/.openclaw/

# On the VM (via the bridge) — same files via the VirtioFS mount
./vm-bridge.sh run 'ls -la /mnt/workspace/agents/researcher/.openclaw/'
```

---

## 11. Known Constraints & Workarounds

| Constraint | Impact | Workaround |
|------------|--------|------------|
| **VirtioFS overwrites `node_modules`** | Local `npm install` inside `/app` would be shadowed by the mount | Install dependencies globally in the Dockerfile; set `NODE_PATH=/usr/local/lib/node_modules` |
| **PM2 argument-stripping bug** | `pm2 start openclaw -- gateway run` loses the `gateway run` arguments | Use `script: "npx", args: "openclaw gateway run"` in `ecosystem.config.js` |
| **SELinux labeling conflicts** | Enforcing mode blocks Podman access to VirtioFS-mounted volumes | Set SELinux to Permissive in the Fedora VM (production: use `:Z` mount labels instead) |
| **Apicurio in-memory storage** | Agent registrations lost on registry restart | 5-second delayed re-registration on bridge startup handles this automatically |
| **No host port exposure** | Cannot `curl` agents directly from macOS host | Use `podman exec` to curl from within the network, or add port mappings to compose |
| **Headless-only output** | Any conversational text corrupts JSON-RPC responses | Enforced via `USER.md` prompt; reviewer sub-agent strips non-JSON output |
| **`openclaw agent` CLI is fire-and-forget** | The CLI returns `{ runId, acceptedAt }` at acceptance, NOT completion, so sub-agent responses (planner/executor/reviewer) are produced after the CLI exits | Bridge speaks the Gateway WS protocol (`connect` → `agent` → subscribe to `chat` events) instead of shelling out to the CLI; it waits for the main session's final synthesized `chat` event (arrives under a resumed runId after the spawn tree finishes). `agent.wait` is raced only for early error detection — it resolves at the first `sessions_yield`, NOT at spawn-tree completion. **In single-agent mode (#9)** there is no `sessions_yield`, so `agent.wait` resolves at run completion and the final `chat` event arrives on the same runId; the bridge still treats the `chat` event as the source of truth |
| **`sessions.history` requires `operator.admin`** | The device is approved for `operator.write` only; `sessions.history` triggers `PAIRING_REQUIRED` | The bridge reads the result from the `chat` event stream instead of calling `sessions.history` |
| **Sub-agent id casing** | `sessions_spawn` targets sub-agents by exact `id`; a mismatched case (e.g. `Executor` vs `executor`) silently fails to resolve | All sub-agent `id` values in `openclaw.json` are lowercase and match the IDs referenced in `IDENTITY.md`/`AGENTS.md` |
| **Sub-agent + A2A cross-agent calls do not work in OpenClaw** | OpenClaw sub-agents cannot reliably drive cross-agent A2A calls, and the prompt-level delegation directive (Researcher's reviewer → Coder) is overridden by the model's task-completion instinct — the reviewer writes the code itself and Coder's bridge never receives a delegation. Proven across 4 end-to-end tests (2026-08-01) with both reviewer and executor as the delegation point. | **Single-agent mode (#9).** The tri-node design is parked pending an OpenClaw fix; artifacts are preserved via JSON5 comments in `openclaw.json`, `IDENTITY.tri-node.md`, and git tag `v0.1.0` (commit `5e428c0`). In single-agent mode, the Researcher's `main` curls the Coder's bridge directly when a task needs code — cross-agent A2A works end-to-end (live-tested 2026-08-11, #10). Making the tri-node fire deterministically is tracked in issues #6 (umbrella), #7 (plugin/extend OpenClaw), and #8 (fork/build a new runtime). |
| **Orchestrator early-termination (moot in single-agent mode)** | The Researcher `main` orchestrator can end its turn mid-loop, capturing narration as the final answer and orphaning the reviewer. Triggered by truncated executor output, the step 5→6 gap, or executor errors. | **Moot in single-agent mode (#9):** `main` does the task itself — there is no spawn loop to terminate early, so this failure mode does not arise. The three guardrails (TRUNCATED-OUTPUT RULE, STEP 5→6 ATOMIC, EXECUTOR ERROR / EMPTY-OUTPUT RULE) are preserved in `IDENTITY.tri-node.md` and will apply again when the tri-node is revived. Full reliability at that point likely requires the same structural enforcement as the sub-agent/A2A issue above. |
| **VS Code agent terminal cannot reach the VM's local subnet** | After a VS Code upgrade, the VS Code integrated terminal (and any process it spawns, including system binaries like `/usr/bin/ssh`) cannot reach hosts on the VM's local subnet (`192.168.64.0/24`) or the LAN (`192.168.100.0/24`). Symptom: `No route to host`. Internet and tailnet IPs still work. The block is at the system network-extension layer, applies to the whole VS Code process session regardless of binary, and is NOT caused by Tailscale, pf, the macOS Application Firewall, TCC Local Network privacy (VS Code is granted), the VS Code agent sandbox (it's off), or the Electron sandbox. An interactive Terminal.app shell on the same Mac CAN reach the VM. | **tmux bridge.** A tmux server started from an interactive Terminal.app shell runs in a working network context. The agent sends commands into the tmux session via `tmux send-keys` and reads captured output from `/tmp` files. The helper script `vm-bridge.sh` (see §10) automates this. The workspace is VirtioFS-mounted at `/mnt/workspace` on the VM, so scripts written on the macOS host are immediately executable on the VM without copying. |

---

*This document is the authoritative architectural reference for the openclaw-workspace PoC. Update it whenever the root configuration files change.*