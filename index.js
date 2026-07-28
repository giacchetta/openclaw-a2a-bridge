const express = require('express');
const WebSocket = require('ws');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(express.json());

const PORT = process.env.AGENT_PORT || 3000;
const ROLE = process.env.AGENT_ROLE || 'Agent';
const REGISTRY_URL = process.env.REGISTRY_URL || 'http://apicurio:8080/apis/registry/v2';
const HOST_IP = process.env.HOST_IP || 'localhost';

// Gateway WS connection (the OpenClaw gateway runs in-container via PM2).
// The CLI `openclaw agent` is fire-and-forget (returns {runId, acceptedAt} at
// acceptance, NOT at completion), so it cannot observe sub-agent delegation.
// We instead speak the documented Gateway WS protocol: `agent` accepts a run,
// `agent.wait` blocks until lifecycle end/error, then `sessions.history` reads
// the final assistant message produced by the planner/executor/reviewer loop.
const GATEWAY_WS_URL = process.env.GATEWAY_WS_URL || 'ws://127.0.0.1:18789';
const GATEWAY_AUTH_TOKEN = process.env.GATEWAY_AUTH_TOKEN || '';
const AGENT_ID = process.env.OPENCLAW_AGENT_ID || 'main';
const SESSION_KEY = process.env.OPENCLAW_SESSION_KEY || 'main';
// agent.wait is wait-only and defaults to 30s; the underlying run can take
// minutes when sub-agents are involved. Use a generous default.
const RUN_TIMEOUT_MS = parseInt(process.env.RUN_TIMEOUT_MS || '600000', 10);
// OpenClaw state dir (same env the gateway reads). Used to locate the device
// identity keypair so the bridge can sign the connect.challenge nonce and
// authenticate as the already-paired CLI client.
const OPENCLAW_STATE_DIR = process.env.OPENCLAW_STATE_DIR || '';

const CONNECT_ROLE = 'operator';
// The device was paired (via `openclaw` CLI first run) with operator.write
// scope. Requesting operator.admin triggers a scope-upgrade pairing flow
// (NOT_PAIRED / PAIRING_REQUIRED) that needs interactive approval, which a
// headless bridge cannot do. We therefore request only the already-approved
// operator.write scope. sessions.history is read via the same operator
// connection; if it needs admin we fall back to reading the run result from
// the agent.wait payload instead.
const CONNECT_SCOPES = ['operator.write'];

/**
 * Load the agent's persisted device identity (Ed25519 keypair + deviceId).
 * The gateway requires a signed device identity on connect to grant operator
 * scopes; the `openclaw` CLI paired on first use and stored this keypair at
 * <stateDir>/identity/device.json. We reuse it so the bridge authenticates as
 * that same paired device instead of going through interactive pairing.
 */
function loadDeviceIdentity() {
    if (!OPENCLAW_STATE_DIR) return null;
    const idPath = path.join(OPENCLAW_STATE_DIR, 'identity', 'device.json');
    try {
        const raw = fs.readFileSync(idPath, 'utf8');
        const id = JSON.parse(raw);
        if (!id.deviceId || !id.publicKeyPem || !id.privateKeyPem) return null;
        return id;
    } catch {
        return null;
    }
}

/** Raw base64url of a PEM Ed25519 public key (the wire format the gateway expects). */
function publicKeyRawBase64UrlFromPem(publicKeyPem) {
    const key = crypto.createPublicKey(publicKeyPem);
    const raw = key.export({ type: 'spki', format: 'der' }).subarray(-32);
    return raw.toString('base64url');
}

/** Sign a UTF-8 payload with a PEM Ed25519 private key, returning base64url. */
function signDevicePayload(privateKeyPem, payload) {
    const key = crypto.createPrivateKey(privateKeyPem);
    return crypto.sign(null, Buffer.from(payload, 'utf8'), key).toString('base64url');
}

function normalizeDeviceMetadataForAuth(value) {
    if (typeof value !== 'string') return '';
    const trimmed = value.trim();
    if (!trimmed) return '';
    return trimmed.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
}

/** Canonical v3 device-auth payload string (matches openclaw buildDeviceAuthPayloadV3). */
function buildDeviceAuthPayloadV3(params) {
    const scopes = params.scopes.join(',');
    const token = params.token ?? '';
    const platform = normalizeDeviceMetadataForAuth(params.platform);
    const deviceFamily = normalizeDeviceMetadataForAuth(params.deviceFamily);
    return [
        'v3', params.deviceId, params.clientId, params.clientMode,
        params.role, scopes, String(params.signedAtMs), token,
        params.nonce, platform, deviceFamily,
    ].join('|');
}

/**
 * Minimal Gateway WS client implementing the challenge-response connect handshake
 * (mirrors the openclaw gateway-client beginPreauthHandshake flow):
 *   1. open the socket — do NOT send connect yet
 *   2. receive the `connect.challenge` event with a nonce (gateway sends it
 *      proactively right after open)
 *   3. send a single signed `connect` with the device signature over the v3
 *      payload (deviceId|clientId|mode|role|scopes|signedAt|token|nonce|...)
 *   4. receive `hello-ok` with the approved operator scopes
 * After that, `request()` sends a frame and resolves with the matching res,
 * and `getFinalAssistantText(sessionKey)` returns the newest final assistant
 * message captured from the `chat` event stream for that session.
 */
function connectGateway() {
    console.error('[bridge] connectGateway() called');
    return new Promise((resolve, reject) => {
        const deviceIdentity = loadDeviceIdentity();
        if (!deviceIdentity) {
            reject(new Error(`No device identity at ${OPENCLAW_STATE_DIR}/identity/device.json — run \`openclaw\` once to pair this agent`));
            return;
        }
        const ws = new WebSocket(GATEWAY_WS_URL);
        const pending = new Map();
        let connectNonce = null;
        let connected = false;
        let connectAttempts = 0;

        const buildClient = () => ({
            id: 'cli',
            displayName: `a2a-bridge-${ROLE}`,
            version: '1.0.0',
            platform: 'linux',
            mode: 'cli',
        });

        const buildConnectParams = (nonce) => {
            const signedAtMs = Date.now();
            const params = {
                minProtocol: 4,
                maxProtocol: 4,
                client: buildClient(),
                role: CONNECT_ROLE,
                scopes: CONNECT_SCOPES,
            };
            if (GATEWAY_AUTH_TOKEN) params.auth = { token: GATEWAY_AUTH_TOKEN };
            if (nonce) {
                const payload = buildDeviceAuthPayloadV3({
                    deviceId: deviceIdentity.deviceId,
                    clientId: params.client.id,
                    clientMode: params.client.mode,
                    role: CONNECT_ROLE,
                    scopes: CONNECT_SCOPES,
                    signedAtMs,
                    token: GATEWAY_AUTH_TOKEN || null,
                    nonce,
                    platform: params.client.platform,
                    deviceFamily: params.client.deviceFamily,
                });
                params.device = {
                    id: deviceIdentity.deviceId,
                    publicKey: publicKeyRawBase64UrlFromPem(deviceIdentity.publicKeyPem),
                    signature: signDevicePayload(deviceIdentity.privateKeyPem, payload),
                    signedAt: signedAtMs,
                    nonce,
                };
            }
            return params;
        };

        const dbg = (m) => {
            const line = `${new Date().toISOString()} ${m}`;
            try { fs.appendFileSync('/tmp/bridge-ws-debug.log', line + '\n'); } catch (e) { /* ignore */ }
            console.error('[dbg]', line);
        };

        // Collect final assistant messages per sessionKey from the chat event
        // stream (sessions.history needs operator.admin which the paired
        // device isn't approved for; see the connect handler for details).
        const finalMessagesBySession = new Map();
        // Waiters for a final assistant message per sessionKey. The chat final
        // event can arrive slightly AFTER agent.wait resolves (race), so we
        // expose waitForFinalAssistantText which waits for the event.
        const finalWaiters = new Map();
        // Track the most recent final assistant text from ANY session as a
        // fallback. The main agent sometimes ends its turn without producing a
        // final message (e.g. it stops after the planner instead of running the
        // full planner→executor→reviewer loop). In that case the main session's
        // final chat event has no message, so we fall back to the last sub-agent's
        // final text (usually the reviewer's, or the planner's if the loop
        // stopped early) so the A2A caller still gets a useful payload.
        let lastFinalText = null;
        // Accumulate assistant delta text per sessionKey. The gateway sometimes
        // emits the chat terminal (state="final") for the main session with NO
        // message field (hasMsg=false) even when the main agent produced a final
        // synthesized answer — the text is delivered via delta events under a
        // different runId (e.g. a resumed/announce run) and the terminal for the
        // original runId has an empty buffer. By accumulating deltas per
        // sessionKey we can reconstruct the final answer as a fallback.
        const deltaTextBySession = new Map();

        const sendConnect = (nonce) => {
            connectAttempts += 1;
            ws.send(JSON.stringify({
                type: 'req', id: 'connect', method: 'connect',
                params: buildConnectParams(nonce),
            }));
        };

        ws.on('open', () => {
            dbg('ws open — waiting for connect.challenge');
        });

        ws.on('message', (data) => {
            let msg;
            try { msg = JSON.parse(String(data)); } catch { dbg('recv UNPARSEABLE'); return; }
            dbg(`recv type=${msg.type} event=${msg.event || ''} id=${msg.id || ''} ok=${msg.ok}`);
            // Debug: log ALL chat events to diagnose the race.
            if (msg.type === 'event' && msg.event === 'chat') {
                dbg(`CHAT runId=${msg.payload?.runId ?? ''} sessionKey=${msg.payload?.sessionKey} state=${msg.payload?.state} hasMsg=${!!msg.payload?.message} role=${msg.payload?.message?.role}`);
            }
            // Debug: log agent lifecycle events with runId + phase.
            if (msg.type === 'event' && msg.event === 'agent') {
                dbg(`AGENT runId=${msg.payload?.runId ?? ''} phase=${msg.payload?.phase ?? msg.payload?.data?.phase ?? ''} stream=${msg.payload?.stream ?? ''}`);
            }

            // Step 2: gateway challenges us with a nonce; sign and send connect.
            if (msg.type === 'event' && msg.event === 'connect.challenge') {
                connectNonce = msg.payload?.nonce;
                if (!connectNonce) { ws.close(); reject(new Error('Gateway connect challenge missing nonce')); return; }
                sendConnect(connectNonce);
                return;
            }

            if (msg.type === 'res' && msg.id === 'connect') {
                if (msg.ok) {
                    connected = true;
                    resolve({
                        request(method, params) {
                            return new Promise((res2, rej2) => {
                                const id = crypto.randomUUID();
                                pending.set(id, { res2, rej2, method });
                                ws.send(JSON.stringify({ type: 'req', id, method, params: params || {} }));
                            });
                        },
                        // Returns a Promise resolving to the final assistant text
                        // for a sessionKey. If the chat final event already arrived,
                        // resolves immediately; otherwise waits up to timeoutMs
                        // for it to arrive (the event can land just after
                        // agent.wait resolves due to a race). Falls back to:
                        //   1. accumulated delta text for the session (the final
                        //      chat event sometimes has no message even when the
                        //      agent produced text, because the text was streamed
                        //      under a different runId)
                        //   2. the last final assistant text from any session (the
                        //      main agent sometimes ends without synthesizing)
                        waitForFinalAssistantText(sessionKey, timeoutMs = 5000) {
                            const existing = finalMessagesBySession.get(sessionKey);
                            if (existing != null) return Promise.resolve(existing);
                            return new Promise((resolve2) => {
                                const timer = setTimeout(() => {
                                    finalWaiters.delete(sessionKey);
                                    const fromFinal = finalMessagesBySession.get(sessionKey);
                                    const fromDelta = deltaTextBySession.get(sessionKey);
                                    const found = fromFinal ?? fromDelta ?? lastFinalText;
                                    const source = fromFinal != null ? 'final' : (fromDelta != null ? 'delta' : (lastFinalText != null ? 'lastFinal' : 'none'));
                                    dbg(`waitForFinalAssistantText timeout — sessionKey=${sessionKey} found=${found != null} source=${source}`);
                                    resolve2(found ?? null);
                                }, timeoutMs);
                                finalWaiters.set(sessionKey, (text) => {
                                    clearTimeout(timer);
                                    finalWaiters.delete(sessionKey);
                                    resolve2(text);
                                });
                            });
                        },
                        close: () => ws.close(),
                    });
                } else {
                    ws.close();
                    reject(new Error(`Gateway connect failed: ${JSON.stringify(msg.error)}`));
                }
                return;
            }

            // Capture final assistant messages from the chat event stream.
            // The gateway emits chat events with state="final" and a `message`
            // object (role="assistant", content=[...]) when an agent turn ends.
            if (msg.type === 'event' && msg.event === 'chat' && msg.payload?.state === 'final' && msg.payload?.message?.role === 'assistant') {
                const sk = msg.payload.sessionKey;
                const content = msg.payload.message.content;
                const text = Array.isArray(content)
                    ? content.map((b) => (typeof b === 'string' ? b : b?.text ?? '')).join('')
                    : (typeof content === 'string' ? content : '');
                if (sk && text) {
                    finalMessagesBySession.set(sk, text);
                    lastFinalText = text;
                    dbg(`captured final assistant text for session=${sk} text=${text.slice(0,80)}`);
                    // Resolve any waiter for this sessionKey.
                    const waiter = finalWaiters.get(sk);
                    if (waiter) waiter(text);
                }
            }

            // Accumulate assistant delta text per sessionKey as a fallback for
            // when the final chat event has no message field (see comment above
            // deltaTextBySession). Deltas carry the streaming assistant text.
            if (msg.type === 'event' && msg.event === 'chat' && msg.payload?.state === 'delta' && msg.payload?.message?.role === 'assistant') {
                const sk = msg.payload.sessionKey;
                const content = msg.payload.message.content;
                const text = Array.isArray(content)
                    ? content.map((b) => (typeof b === 'string' ? b : b?.text ?? '')).join('')
                    : (typeof content === 'string' ? content : '');
                if (sk && text) {
                    // Deltas may be incremental fragments or full accumulated
                    // text depending on the gateway version. Append; the final
                    // assembled text is what matters for the fallback.
                    const prev = deltaTextBySession.get(sk) ?? '';
                    // Heuristic: if the new text starts with the previous text,
                    // it's an accumulated snapshot — replace. Otherwise append.
                    if (prev && text.startsWith(prev)) deltaTextBySession.set(sk, text);
                    else deltaTextBySession.set(sk, prev + text);
                }
            }

            if (msg.type === 'res' && pending.has(msg.id)) {
                const { res2, rej2, method } = pending.get(msg.id);
                pending.delete(msg.id);
                if (method === 'agent') dbg(`agent resolved ok=${msg.ok} runId=${msg.payload?.runId ?? ''} sessionKey=${msg.payload?.sessionKey ?? ''} acceptedAt=${msg.payload?.acceptedAt ?? ''}`);
                if (method === 'agent.wait') dbg(`agent.wait resolved ok=${msg.ok} status=${msg.payload?.status} runId=${msg.payload?.runId ?? ''} sessionKeys=${JSON.stringify([...finalMessagesBySession.keys()])}`);
                msg.ok ? res2(msg.payload) : rej2(new Error(`Gateway ${msg.id} error: ${JSON.stringify(msg.error)}`));
            }
            // other event frames are intentionally ignored
        });

        ws.on('error', (err) => { dbg(`ws error: ${err.message}`); if (!connected) reject(err); });
        ws.on('close', () => {
            dbg('ws close');
            for (const { rej2 } of pending.values()) rej2(new Error('Gateway socket closed before response'));
            pending.clear();
        });
    });
}

const agentCard = {
    name: ROLE,
    version: "1.0.0",
    description: `Specialized OpenClaw node acting as ${ROLE}`,
    protocols: ["A2A", "JSON-RPC 2.0"],
    endpoint: `http://${HOST_IP}:${PORT}/a2a/tasks`
};

app.get('/.well-known/agent.json', (req, res) => {
    res.json(agentCard);
});

/**
 * Run a task against the local OpenClaw gateway and wait for completion.
 *
 * Lifecycle (per docs/concepts/concepts/agent-loop.md and session-tool.md):
 *   1. `agent`      -> { runId, acceptedAt }  (acceptance, NOT completion)
 *   2. The main agent delegates to planner/executor/reviewer via
 *      `sessions_spawn` (non-blocking) + `sessions_yield`. `sessions_yield`
 *      ENDS the current turn, which ends the lifecycle for the original
 *      `runId`. The sub-agents keep running in the background; when they
 *      complete, a NEW turn (new runId) starts on the main session to process
 *      the completion event and synthesize the final answer.
 *   3. `agent.wait` on the original runId therefore resolves at the FIRST
 *      yield — NOT when the whole spawn tree finishes. We use it only to
 *      detect early lifecycle errors; we do NOT treat its resolution as
 *      completion.
 *   4. The final synthesized answer arrives as a `chat` event with
 *      state="final" and message.role="assistant" on the main session, under
 *      a LATER runId. We wait for that event (bounded by RUN_TIMEOUT_MS).
 *      We cannot use sessions.history because it requires operator.admin
 *      scope, which the paired device isn't approved for (requesting it
 *      triggers a PAIRING_REQUIRED scope-upgrade that needs interactive
 *      approval).
 *
 * Fallbacks if the main session's final chat event has no message (the
 * gateway sometimes suppresses the message field when the text was streamed
 * under a different runId, or the main agent ends without synthesizing):
 *   a. accumulated assistant delta text for the main session
 *   b. the last final assistant text from any sub-agent session
 */
async function runTask(taskInstruction) {
    const gw = await connectGateway();
    try {
        const idempotencyKey = `a2a-${crypto.randomUUID()}`;
        const accepted = await gw.request('agent', {
            agentId: AGENT_ID,
            sessionKey: SESSION_KEY,
            message: taskInstruction,
            idempotencyKey,
        });
        const runId = accepted?.runId;
        if (!runId) throw new Error(`Gateway 'agent' did not return runId: ${JSON.stringify(accepted)}`);
        // The gateway normalizes the sessionKey to "agent:<agentId>:<sessionKey>"
        // (e.g. "main" -> "agent:main:main"). Use the normalized form returned by
        // the agent call to look up the final chat event for THIS session.
        const fullSessionKey = accepted?.sessionKey || `agent:${AGENT_ID}:${SESSION_KEY}`;

        // agent.wait resolves at the FIRST sessions_yield (lifecycle end of the
        // original runId), NOT when the spawn tree finishes. Use it only to
        // surface early lifecycle errors; race it against waiting for the final
        // synthesized assistant text on the main session (which arrives later,
        // under a resumed runId, after all sub-agents complete).
        const waitPromise = gw.request('agent.wait', {
            runId,
            timeoutMs: RUN_TIMEOUT_MS,
        }).catch((err) => ({ __error: err.message }));

        // Wait for the final synthesized assistant text on the main session.
        // This is the real completion signal — it arrives after the whole
        // planner→executor→reviewer loop finishes and the main agent resumes to
        // emit its final answer. Bound by RUN_TIMEOUT_MS.
        let output = await gw.waitForFinalAssistantText(fullSessionKey, RUN_TIMEOUT_MS);

        // Inspect agent.wait result for early errors (don't let it block — by
        // now waitForFinalAssistantText has already resolved or timed out).
        const waited = await Promise.race([
            waitPromise,
            Promise.resolve({ __pending: true }),
        ]);
        if (waited?.status === 'error') {
            throw new Error(`Agent run errored: ${waited.error || 'unknown error'}`);
        }

        // Try to parse as JSON for structured A2A consumers; fall back to raw.
        let parsedOutput = output;
        if (typeof output === 'string') {
            try { parsedOutput = JSON.parse(output); } catch { /* keep raw string */ }
        }
        return {
            status: waited?.status || 'ok',
            runId,
            endedAt: waited?.endedAt,
            output: parsedOutput,
        };
    } finally {
        gw.close();
    }
}

app.post('/a2a/tasks', async (req, res) => {
    try {
        const payload = req.body;
        const taskInstruction = payload.params?.task || "status";

        console.log(`[${ROLE}] Received A2A payload. Routing to OpenClaw Gateway (agent.wait lifecycle)...`);

        const result = await runTask(taskInstruction);

        res.json({
            jsonrpc: "2.0",
            result: { status: "success", agent: ROLE, output: result.output, runId: result.runId, runStatus: result.status },
            id: payload.id || null
        });
    } catch (error) {
        console.error(`[${ROLE}] Execution Error:`, error.message);
        res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: error.message }});
    }
});

app.listen(PORT, async () => {
    console.log(`[${ROLE}] Bridge initialized on port ${PORT}`);
    
    // Slight delay to ensure Apicurio is fully up in Compose
    setTimeout(async () => {
        try {
            const response = await fetch(`${REGISTRY_URL}/groups/default/artifacts`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-Registry-ArtifactId': ROLE,
                    'X-Registry-ArtifactType': 'JSON'
                },
                body: JSON.stringify(agentCard)
            });
            
            if (response.ok) console.log(`[${ROLE}] Successfully registered with Apicurio!`);
            else if (response.status === 409) console.log(`[${ROLE}] Agent Card already exists.`);
            else console.error(`[${ROLE}] Failed to register. Status: ${response.status}`);
        } catch (error) {
            console.error(`[${ROLE}] Error reaching Apicurio:`, error.message);
        }
    }, 5000);
});

