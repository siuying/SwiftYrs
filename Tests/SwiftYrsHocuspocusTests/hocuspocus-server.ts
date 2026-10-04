import { Server } from "@hocuspocus/server";
import * as decoding from "lib0/decoding";
import * as readline from "node:readline";

const authToken = process.env.HOCUSPOCUS_AUTH_TOKEN ?? null;
const trace = process.env.HOCUSPOCUS_TRACE === "1";
let sequence = 0;

function emitTrace(value: Record<string, unknown>) {
  sequence += 1;
  console.log(JSON.stringify({ ...value, sequence }));
}

// Awareness frames: document name, message type 1, then the encoded update.
function traceFrame(data: Uint8Array) {
  const decoder = decoding.createDecoder(data);
  decoding.readVarString(decoder);
  if (decoding.readVarUint(decoder) !== 1) {
    return;
  }
  const update = decoding.createDecoder(decoding.readVarUint8Array(decoder));
  const clients = [];
  for (let count = decoding.readVarUint(update); count > 0; count -= 1) {
    clients.push({
      clientID: decoding.readVarUint(update),
      clock: decoding.readVarUint(update),
      state: decoding.readVarString(update),
    });
  }
  emitTrace({ type: "awarenessFrame", clients });
}

const server = new Server({
  port: 0,
  quiet: true,
  async onAuthenticate({ token }) {
    if (authToken !== null && token !== authToken) {
      throw new Error("invalid token");
    }
  },
  async onStateless({ document, payload }) {
    document.broadcastStateless(payload);
  },
});

if (trace) {
  // Frames and close events reach the connection in wire order.
  const handleConnection = server.hocuspocus.handleConnection.bind(server.hocuspocus);
  server.hocuspocus.handleConnection = (incoming, request, context) => {
    const connection = handleConnection(incoming, request, context);
    const handleMessage = connection.handleMessage;
    connection.handleMessage = (data: Uint8Array) => {
      traceFrame(data);
      handleMessage(data);
    };
    const handleClose = connection.handleClose.bind(connection);
    connection.handleClose = event => {
      emitTrace({ type: "close" });
      handleClose(event);
    };
    return connection;
  };
}

await server.listen(0, ({ port }: { port: number }) => {
	console.log(JSON.stringify({ type: "ready", port }));
});

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", async line => {
	if (line.trim() === "shutdown") {
		await server.destroy();
		process.exit(0);
	}
});
