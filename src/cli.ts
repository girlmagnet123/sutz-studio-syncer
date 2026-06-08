#!/usr/bin/env node
import { SutzDaemon } from "./daemon.js";

const port = Number(process.env.SUTZ_PORT ?? 8181);
const host = process.env.SUTZ_HOST ?? "127.0.0.1";
const syncDir = process.env.SUTZ_SYNC_DIR ?? "sync";
const portScanCount = Number(process.env.SUTZ_PORT_SCAN ?? 10);

if (!Number.isInteger(port) || port <= 0) {
  throw new Error(`Invalid SUTZ_PORT: ${process.env.SUTZ_PORT}`);
}

const daemon = new SutzDaemon({ host, port, syncDir, portScanCount });

try {
  await daemon.start();
} catch (error) {
  if (isNodeError(error) && error.code === "EADDRINUSE") {
    console.error(
      `Ports ${host}:${port}-${port + portScanCount - 1} are all in use. ` +
        `Stop an existing daemon, raise SUTZ_PORT_SCAN, or set SUTZ_PORT to another base port.`,
    );
    process.exit(1);
  }

  throw error;
}

let stopping = false;
const stop = async (signal: string): Promise<void> => {
  if (stopping) {
    return;
  }

  stopping = true;
  console.log(`Received ${signal}; shutting down.`);
  await daemon.stop();
  process.exit(0);
};

process.on("SIGINT", () => {
  void stop("SIGINT");
});

process.on("SIGTERM", () => {
  void stop("SIGTERM");
});

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && "code" in error;
}
