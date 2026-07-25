import { readFile } from "node:fs/promises";
import { connect } from "node:net";
import { join } from "node:path";

const signalFileName = ".weaver-dev-port";

function connectOnce(port: number): Promise<void> {
  return new Promise((resolvePromise, reject) => {
    const socket = connect({ host: "127.0.0.1", port });
    socket.setTimeout(1_000);
    socket.once("connect", () => {
      socket.end();
      resolvePromise();
    });
    socket.once("timeout", () => socket.destroy(new Error("dev reload endpoint timed out")));
    socket.once("error", reject);
  });
}

export async function signalDevReload(projectDirectory: string, attempts = 20): Promise<void> {
  const signalPath = join(projectDirectory, "dist", signalFileName);
  let lastError: unknown = new Error(`dev reload endpoint is unavailable: ${signalPath}`);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const portText = await readFile(signalPath, "utf8");
      const port = Number(portText.trim());
      if (!Number.isSafeInteger(port) || port < 1 || port > 65_535) throw new Error(`invalid dev reload port in ${signalPath}`);
      await connectOnce(port);
      return;
    } catch (error) {
      lastError = error;
      if (attempt + 1 < attempts) await new Promise((resolvePromise) => setTimeout(resolvePromise, 25));
    }
  }
  throw lastError;
}
