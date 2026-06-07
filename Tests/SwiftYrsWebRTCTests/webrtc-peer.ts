// A real browser-grade y-webrtc peer for the interop E2E. Runs the actual
// `y-webrtc` npm package under node with `@roamhq/wrtc` injected via
// `peerOpts.wrtc` (node has no native WebRTC), so the simple-peer seam in
// SwiftYrsWebRTC is validated against the genuine implementation. Speaks the
// same newline-delimited JSON control protocol over stdio as hocuspocus-peer.ts.

import * as Y from "yjs";
import { WebrtcProvider } from "y-webrtc";
import wrtc from "@roamhq/wrtc";
import * as readline from "node:readline";

const [signalingUrl, room] = process.argv.slice(2);
if (signalingUrl === undefined || room === undefined) {
  throw new Error("usage: node webrtc-peer.ts <signaling-url> <room>");
}

const doc = new Y.Doc();
const text = doc.getText("body");

function emit(value: unknown) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

const provider = new WebrtcProvider(room, doc, {
  signaling: [signalingUrl],
  peerOpts: { wrtc },
  // Keep this peer isolated to the WebRTC mesh; no BroadcastChannel cross-talk.
  filterBcConns: false,
} as any);

provider.on("synced", ({ synced }: { synced: boolean }) => {
  if (synced) {
    emit({ type: "synced" });
  }
});

emit({ type: "ready" });

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return;
  }
  const command = JSON.parse(trimmed);
  switch (command.type) {
    case "insertText":
      text.insert(command.index ?? text.length, command.text);
      emit({ type: "ok" });
      break;
    case "getText":
      emit({ type: "text", text: text.toString() });
      break;
    case "shutdown":
      provider.destroy();
      emit({ type: "ok" });
      process.exit(0);
      break;
    default:
      emit({ type: "error", message: `Unknown command: ${command.type}` });
  }
});
