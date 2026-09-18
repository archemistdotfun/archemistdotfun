import fs from 'node:fs';

export function loadDotEnv(envPath) {
  if (!fs.existsSync(envPath)) throw new Error(`Environment file not found: ${envPath}`);
  const source = fs.readFileSync(envPath, 'utf8');
  for (const rawLine of source.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const match = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/u);
    if (!match || process.env[match[1]] !== undefined) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      value = value.replace(/\s+#.*$/u, '').trim();
    }
    process.env[match[1]] = value;
  }
}

export function privateKeyFromEnv(key) {
  const value = process.env[key];
  if (!value) throw new Error(`Missing ${key}`);
  const normalized = value.startsWith('0x') ? value : `0x${value}`;
  if (!/^0x[0-9a-fA-F]{64}$/u.test(normalized)) throw new Error(`${key} is not a 32-byte hex private key`);
  return normalized;
}
