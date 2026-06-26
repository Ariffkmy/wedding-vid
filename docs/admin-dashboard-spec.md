# Admin Dashboard — Specification

Monitoring & administration console for the Kawenreel (PalmierPro) macOS app: token usage,
users, logs, provider/model configuration, and BYOK key status.

> Status: draft spec for a net-new web dashboard. Grounded in the current app architecture
> (Swift 6.2 macOS app, Clerk auth, Convex backend, OpenRouter + Anthropic agent providers).

---

## 1. Goals

- Central visibility into **agent token consumption** across all users, by user / model / provider / time.
- **User directory**: identity, plan/credits, activity, configured provider.
- **Operational logs & telemetry** for support and debugging.
- **Provider control plane**: the admin-managed default OpenRouter model ("Default Setting"), model allow-list.
- **BYOK key status** (Anthropic / OpenRouter): presence, placement, last-changed — **never the secret itself**.
- Foundation for the future **credit-mapping** layer (token → cost → credits), which is intentionally out of scope here but must not be blocked.

## 2. Non-goals

- Reading or storing users' raw API keys (BYOK keys live in each user's macOS Keychain and must stay there).
- Editing timelines / projects.
- Replacing Clerk or Convex; the dashboard reads/extends them.

---

## 3. Current architecture (data sources of record)

| Concern | Where it lives today | Symbol / location |
|---|---|---|
| User identity & auth | **Clerk** | `BackendConfig.clerkPublishableKey`, `Clerk.shared.session` |
| Account, plan, credits | **Convex** (decoded client-side) | `AccountService`, `AccountResponse{user,plan}`; `convexDeploymentURL` / `convexHttpURL` |
| Managed agent streaming (proxy) | **Convex HTTP** | `PalmierClient` → `…/v1/agent/stream` |
| BYOK Anthropic key | **macOS Keychain (local)** | `AnthropicKeychain` account `"anthropic-api-key"` |
| BYOK OpenRouter key | **macOS Keychain (local)** | `OpenRouterKeychain` account `"openrouter-api-key"` |
| Selected provider mode | **UserDefaults (local)** | `AgentProviderMode` (`defaultSetting` / `claudeOwnKey`), key `"agentProviderMode"` |
| OpenRouter model | **UserDefaults (local)** | key `"agentOpenRouterModel"`, default `google/gemini-2.5-flash-lite` |
| Anthropic model | enum | `AnthropicModel` (`claude-sonnet-4-6`, `claude-opus-4-8`, `claude-haiku-4-5`) |
| Token usage | **Local JSON (per-machine)** | `TokenUsageTracker` → `~/Library/Application Support/PalmierPro/token-usage.json` |
| Logs / crashes | **Local + Sentry** | `Log.*` (os.Logger), `~/Library/Logs/PalmierPro/crash.log`, Sentry breadcrumbs |

### 3.1 Critical gap to resolve first
Token usage and key/provider state are **local to each device**. Nothing is centralized.
**A reporting pipeline (client → backend) is a prerequisite** for every monitoring module below.
The dashboard reads the backend; the app must start emitting these records. See §6.

### 3.2 Hard constraint: secrets never leave the device
BYOK keys are in the Keychain. The app may report **metadata** (key present? which provider? masked
last-4? last-changed timestamp?) but must **never transmit the secret**. The dashboard shows status, not keys.

---

## 4. Canonical data model (to ingest server-side)

These extend what already exists in code; field names mirror current symbols.

### 4.1 `usage_event` (new — from `TokenUsageRecord`)
```
id              uuid
user_id         string   // Clerk user id (added at report time)
device_id       string   // stable per-install id (added at report time)
ts              datetime // TokenUsageRecord.date
provider        enum     // AgentProvider: anthropic | openAICompatible
model           string   // ACTUAL model used (e.g. claude-sonnet-4-6 OR anthropic/claude-sonnet-4.5)
provider_mode   enum     // AgentProviderMode at request time: defaultSetting | claudeOwnKey
input_tokens    int      // uncached prompt
output_tokens   int
cache_read_tokens   int
cache_write_tokens  int
total_tokens    int (derived)
session_id      string?  // ChatSession id, to group a run
app_version     string   // CFBundleShortVersionString
```
> Note: `model` is the real per-request model (the requirement: even via OpenRouter, an Anthropic
> model is recorded as its slug). Keep counts additive/non-overlapping (already normalized client-side).

### 4.2 `user` (from Clerk + `AccountResponse`)
```
user_id, email, name, image            // Clerk + AccountUser
tier                                    // AccountTier
current_period_end, cancel_at_period_end
spent_credits_this_period, purchased_credits
monthly_budget_credits                  // AccountPlan
remaining_credits (derived)             // budget - spent
created_at, last_seen_at
```

### 4.3 `provider_config_state` (new — telemetry snapshot)
```
user_id, device_id, ts
provider_mode                           // defaultSetting | claudeOwnKey
openrouter_model                        // agentOpenRouterModel
anthropic_key_present  bool             // metadata only
anthropic_key_last4    string?          // masked
anthropic_key_changed_at datetime?
openrouter_key_present bool
openrouter_key_last4   string?
openrouter_key_changed_at datetime?
```

### 4.4 `admin_default_model` (new — control plane, server-owned)
```
openrouter_model        string          // the "admin's setting" referenced in product
allowed_models          string[]        // curated allow-list pushed to clients
updated_by, updated_at
```

### 4.5 `log_event` (from `Log` categories / Sentry)
```
id, user_id?, device_id, ts
category        // app|editor|export|preview|mcp|agent|account|generation|project|transcription|search
level           // notice|warn|error|fault
message
app_version, os_version
```

---

## 5. Dashboard modules

### 5.1 Token Usage (primary)
- **Overview**: total tokens (input/output/cache) across all users; today / 7d / 30d; trend chart.
- **By model**: table + chart keyed by `model` (the real slug). This is the unit the future credit
  map attaches to. Show input/output/cache split per model (pricing differs by model & cache type).
- **By provider**: anthropic vs openAICompatible; and by `provider_mode` (BYOK vs Default Setting).
- **By user**: top consumers, drill into a user's `usage_event` history.
- **By session**: group a single editing run (`session_id`) — tokens, request count, duration
  (last_event_ts − first_event_ts), tools invoked if logged.
- **Cache efficiency**: cache_read / (input+cache_read) — surfaces prompt-cache hit rate.
- Filters: date range, user, model, provider, provider_mode, app_version.
- Export: CSV / JSON.

### 5.2 Users & Profiles
- Directory: email, name, avatar, tier, plan, credits remaining, last seen, current provider_mode.
- Profile page: identity (Clerk), plan & credits (Convex), lifetime tokens (by model), recent
  sessions, recent logs, provider/key status (§5.5).
- Actions (gated): impersonate-view (read-only), flag account, link to Clerk/Convex/Stripe records.

### 5.3 API Token Usage (provider-side reconciliation) — optional, high-value
- Compare **app-reported** usage vs **provider-reported** usage:
  - OpenRouter: `/api/v1/generation` / activity / key-usage endpoints.
  - Anthropic: org usage/cost API (only for org-owned keys, not user BYOK).
- Surfaces drift, untracked spend, and validates the client tracker.

### 5.4 Provider & Model Control Plane
- View/set **admin default OpenRouter model** (`admin_default_model.openrouter_model`) — the
  "Default Setting" target. Default today is `google/gemini-2.5-flash-lite`.
- Manage **allowed models** list pushed to clients (replaces the removed in-chat curated list).
- Show distribution: how many users on Default Setting vs Claude (BYOK), and which models are active.
- (Client work required: have the app fetch `admin_default_model` instead of the local UserDefaults default.)

### 5.5 API Key Placement & Status (BYOK)
- Per user/device: Anthropic key present?, OpenRouter key present?, masked last-4, last-changed.
- Aggregate: % of users with each key type; users on `claudeOwnKey` **without** an Anthropic key
  (mis-config → agent can't run); OpenRouter default-only users.
- **No secret values, ever.** Source: `provider_config_state` telemetry.

### 5.6 Logs & Telemetry
- Stream/search `log_event` by category/level/user/time; deep-link to Sentry issue.
- Error & crash rates by app_version; top error messages; agent tool failure rates
  (already logged as `[agent] tool failed name=…`).

### 5.7 Credits & Billing (read-only here; mapping is a separate project)
- Per user: budget, spent, purchased, remaining, period end, cancel-at-period-end.
- Plan/tier distribution, MRR proxy from `AccountPlan.monthlyPriceUsd`.
- Placeholder for the future **token→credit** mapping (keyed by `model`).

### 5.8 Alerts & Anomalies
- Spikes in per-user or global token usage; cost thresholds; error/crash spikes;
  users hitting credit budget; sudden model-mix shifts. Notify via email/Slack.

---

## 6. Ingestion pipeline (client → backend) — required enabler

1. **Extend `TokenUsageTracker`** to also POST each `usage_event` (batched, retry, offline queue)
   to the backend, tagged with Clerk `user_id`, `device_id`, `session_id`, `app_version`.
   Keep the local JSON as a cache/fallback.
2. **Emit `provider_config_state`** on change of `AgentProviderMode`, `agentOpenRouterModel`,
   or key add/remove (hook the existing `…APIKeyChanged` notifications). Metadata only.
3. **Forward logs**: Sentry already receives breadcrumbs/errors; optionally mirror `notice`/`warn`/`error`
   to the backend for in-dashboard search (sample to control volume).
4. **Auth on ingest**: reuse Clerk JWT (same token `PalmierClient` already attaches) so events are
   attributable and tamper-resistant.
5. **Privacy**: never send prompt/clip content — counts and metadata only.

---

## 7. Backend & storage options

Two backends are already in play; pick per team preference:

- **Convex** (already integrated, Clerk-aware): add `usage_event`, `provider_config_state`,
  `admin_default_model` tables + ingest mutations + admin queries. Lowest friction, reuses auth.
- **Supabase** (available via MCP tooling): Postgres + RLS + SQL analytics; strong for ad-hoc
  usage queries and BI. Good if you want SQL/Metabase-style reporting.

Recommendation: **Convex for ingestion + control plane** (auth & app integration), optionally
mirror `usage_event` to **Supabase/Postgres** for heavy analytics if needed.

---

## 8. Admin web app

- **Stack**: Next.js (App Router) + TypeScript; Clerk for **admin** auth with an `admin` role/allow-list;
  data via Convex client or Supabase; charts (Recharts/visx); table (TanStack Table).
- **AuthZ**: admin-only; role claim in Clerk; audit every privileged action (model changes, flags).
- **Deploy**: Vercel (MCP available).

---

## 9. Security, privacy, compliance

- Secrets: BYOK keys never leave device; dashboard shows presence/last-4 only.
- PII: emails/names/avatars from Clerk — apply access controls & retention.
- Content: no prompts, transcripts, or media leave the device for monitoring.
- Audit log for all admin actions; least-privilege admin roles.
- Data retention policy for `usage_event` / `log_event` (e.g. raw 90d, rollups indefinite).

---

## 10. Phasing

1. **P0 — Ingestion**: `usage_event` reporting + Convex tables + minimal Token Usage page (global + by model + by user).
2. **P1 — Users & Keys**: user directory/profile, `provider_config_state`, key-status & provider-mix views.
3. **P2 — Control plane**: admin default OpenRouter model + allow-list, client fetches it.
4. **P3 — Logs & Alerts**: log search, error/crash dashboards, anomaly alerts.
5. **P4 — Reconciliation & Credits**: provider-side usage compare; hook for token→credit mapping.

---

## 11. Open decisions

- Backend: Convex-only vs Convex + Supabase analytics mirror.
- `device_id` scheme (stable per install; how to handle multiple devices per user).
- Log volume/sampling and retention.
- Whether "Default Setting" should be fully server-driven now (enables §5.4 control plane).
- Admin role source of truth in Clerk.
```
