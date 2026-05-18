#!/usr/bin/env node
import { SutzDaemon } from "./daemon.js";

const port = Number(process.env.SUTZ_PORT ?? 8181);
const host = process.env.SUTZ_HOST ?? "127.0.0.1";

if (!Number.isInteger(port) || port <= 0) {
  throw new Error(`Invalid SUTZ_PORT: ${process.env.SUTZ_PORT}`);
}

const daemon = new SutzDaemon({ host, port });

await daemon.start();

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
