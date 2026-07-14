export function originHost(urlText: string): string | null {
  try {
    const url = new URL(urlText);
    return url.protocol === "https:" ? url.host : null;
  } catch {
    return null;
  }
}

export function validOriginHost(value: unknown): value is string {
  if (typeof value !== "string" || value.length === 0 || value.includes("://") || /[/?#@]/.test(value)) return false;
  try {
    const url = new URL(`https://${value}`);
    return url.host.toLowerCase() === value.toLowerCase() && url.pathname === "/";
  } catch {
    return false;
  }
}

export function originDeclared(origins: readonly string[], host: string): boolean {
  return origins.some((origin) => origin.toLowerCase() === host.toLowerCase());
}

export function originNotDeclaredMessage(host: string): string {
  return `OriginNotDeclared: add "${host}" to origins in your widget config`;
}
