// Minimal y-webrtc signaling server (pub/sub relay over WebSocket), mirroring
// yjs/y-webrtc bin/server.js, for the Swift↔Swift E2E. Clients subscribe to
// room topics and publish announce/signal messages; the server forwards each
// publish to every subscriber of the topic (including the sender, which filters
// its own messages). Emits a `ready` line with the bound port on stdout.

interface ConnData {
  topics: Set<string>;
}

const topics = new Map<string, Set<any>>();

const server = Bun.serve<ConnData, undefined>({
  port: 0,
  hostname: "127.0.0.1",
  fetch(req, server) {
    if (server.upgrade(req, { data: { topics: new Set<string>() } })) {
      return;
    }
    return new Response("okay");
  },
  websocket: {
    message(ws, raw) {
      let message: any;
      try {
        message = JSON.parse(typeof raw === "string" ? raw : raw.toString());
      } catch {
        return;
      }
      if (!message || !message.type) {
        return;
      }
      switch (message.type) {
        case "subscribe":
          for (const topicName of message.topics ?? []) {
            if (typeof topicName !== "string") continue;
            let subs = topics.get(topicName);
            if (!subs) {
              subs = new Set();
              topics.set(topicName, subs);
            }
            subs.add(ws);
            ws.data.topics.add(topicName);
          }
          break;
        case "unsubscribe":
          for (const topicName of message.topics ?? []) {
            topics.get(topicName)?.delete(ws);
          }
          break;
        case "publish":
          if (message.topic) {
            const receivers = topics.get(message.topic);
            if (receivers) {
              message.clients = receivers.size;
              const payload = JSON.stringify(message);
              for (const receiver of receivers) {
                receiver.send(payload);
              }
            }
          }
          break;
        case "ping":
          ws.send(JSON.stringify({ type: "pong" }));
          break;
      }
    },
    close(ws) {
      for (const topicName of ws.data.topics) {
        const subs = topics.get(topicName);
        if (subs) {
          subs.delete(ws);
          if (subs.size === 0) topics.delete(topicName);
        }
      }
      ws.data.topics.clear();
    },
  },
});

console.log(JSON.stringify({ type: "ready", port: server.port }));

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  for (const line of chunk.split("\n")) {
    if (line.trim() === "shutdown") {
      server.stop(true);
      process.exit(0);
    }
  }
});
