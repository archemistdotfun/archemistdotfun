import { custom } from 'viem';

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * One shared JSON-RPC lane for every viem client. ARC's public endpoint can
 * return 429 under bursts, so calls are serialized, spaced, and retried.
 */
export function createSerializedRpcTransport(rpcUrls, {
  minIntervalMs = 175,
  maxRetries = 7,
  baseDelayMs = 500,
  timeoutMs = 180_000,
} = {}) {
  const endpoints = [...new Set((Array.isArray(rpcUrls) ? rpcUrls : [rpcUrls])
    .filter((value) => typeof value === 'string' && /^https?:\/\//u.test(value)))];
  if (endpoints.length === 0) throw new Error('At least one HTTP(S) RPC endpoint is required');
  let tail = Promise.resolve();
  let lastStartedAt = 0;
  let requestId = 0;
  let preferredEndpoint = 0;
  const stats = { endpointCount: endpoints.length, failovers: 0, retries: 0 };

  async function perform(method, params) {
    for (let attempt = 0; attempt <= maxRetries; attempt += 1) {
      const endpointIndex = (preferredEndpoint + attempt) % endpoints.length;
      const waitMs = Math.max(0, minIntervalMs - (Date.now() - lastStartedAt));
      if (waitMs > 0) await delay(waitMs);
      lastStartedAt = Date.now();

      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetch(endpoints[endpointIndex], {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: ++requestId, method, params: params ?? [] }),
          signal: controller.signal,
        });
        const retryable = response.status === 429 || response.status === 408 || response.status >= 500;
        if (retryable && attempt < maxRetries) {
          stats.retries += 1;
          if (endpointIndex !== preferredEndpoint) stats.failovers += 1;
          const retryAfter = Number(response.headers.get('retry-after'));
          const backoff = Number.isFinite(retryAfter) && retryAfter > 0
            ? retryAfter * 1_000
            : Math.min(30_000, baseDelayMs * (2 ** attempt));
          await response.arrayBuffer();
          await delay(backoff);
          continue;
        }
        if (!response.ok) throw new Error(`RPC HTTP ${response.status} ${response.statusText}`);
        const payload = await response.json();
        if (payload.error) {
          const error = new Error(payload.error.message ?? 'JSON-RPC error');
          error.code = payload.error.code;
          error.data = payload.error.data;
          throw error;
        }
        preferredEndpoint = endpointIndex;
        return payload.result;
      } catch (error) {
        const retryableNetworkError = error?.name === 'AbortError' || error instanceof TypeError;
        if (!retryableNetworkError || attempt === maxRetries) throw error;
        stats.retries += 1;
        if (endpoints.length > 1) stats.failovers += 1;
        await delay(Math.min(30_000, baseDelayMs * (2 ** attempt)));
      } finally {
        clearTimeout(timeout);
      }
    }
    throw new Error(`RPC retry budget exhausted for ${method}`);
  }

  const provider = {
    request({ method, params }) {
      const scheduled = tail.then(() => perform(method, params));
      tail = scheduled.catch(() => undefined);
      return scheduled;
    },
  };
  const transport = custom(provider, { name: 'ARC serialized throttled failover JSON-RPC', retryCount: 0 });
  transport.rpcStats = stats;
  return transport;
}
