import { createInterface } from "node:readline";
import { ClaudeBridge } from "./bridge.js";
import {
  JSONRPCError,
  sendError,
  sendResult,
  type IncomingJSONRPCMessage,
  type ProtocolWriter,
} from "./protocol.js";

const writer: ProtocolWriter = (value) => {
  process.stdout.write(`${JSON.stringify(value)}\n`);
};
const bridge = new ClaudeBridge(writer);
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });

input.on("line", (line) => {
  void receiveLine(line);
});

input.on("close", () => {
  void bridge.handle("shutdown", {}).finally(() => process.exit(0));
});

async function receiveLine(line: string): Promise<void> {
  let message: IncomingJSONRPCMessage;
  try {
    message = JSON.parse(line) as IncomingJSONRPCMessage;
  } catch {
    writer({
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: "Invalid JSON." },
    });
    return;
  }

  if (message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    if ("id" in message) {
      sendError(writer, message.id, new JSONRPCError(-32600, "Invalid JSON-RPC request."));
    }
    return;
  }
  if (!("id" in message)) {
    try {
      await bridge.handle(message.method, message.params);
    } catch {
      // Notifications have no caller awaiting an error response. Do not write
      // provider exceptions to stderr because they may contain user content.
      console.error("Claude bridge notification failed.");
    }
    return;
  }

  try {
    const result = await bridge.handle(message.method, message.params);
    sendResult(writer, message.id, result);
    if (message.method === "shutdown") {
      input.close();
    }
  } catch (error) {
    sendError(writer, message.id, error);
  }
}
