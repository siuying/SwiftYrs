// Minimal y-webrtc signaling server (pub/sub relay over WebSocket), mirroring
// yjs/y-webrtc bin/server.js, for the Swift↔Swift E2E. Clients subscribe to
// room topics and publish announce/signal messages; the server forwards each
// publish to every subscriber of the topic (including the sender, which filters
// its own messages). Emits a `ready` line with the bound port on stdout.

import { createServer } from "node:http";
import { WebSocketServer, type WebSocket } from "ws";

interface ConnData {
  topics: Set<string>;
}

type SignalingSocket = WebSocket & ConnData;

const topics = new Map<string, Set<SignalingSocket>>();
const httpServer = createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/plain" });
  response.end("okay");
});
const websocketServer = new WebSocketServer({ server: httpServer });

websocketServer.on("connection", (socket: SignalingSocket) => {
  socket.topics = new Set<string>();

  socket.on("message", raw => {
    let message: any;
    try {
      message = JSON.parse(raw.toString());
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
        subs.add(socket);
        socket.topics.add(topicName);
      }
      break;
    case "unsubscribe":
      for (const topicName of message.topics ?? []) {
        topics.get(topicName)?.delete(socket);
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
      socket.send(JSON.stringify({ type: "pong" }));
      break;
    }
  });

  socket.on("close", () => {
    for (const topicName of socket.topics) {
      const subs = topics.get(topicName);
      if (subs) {
        subs.delete(socket);
        if (subs.size === 0) topics.delete(topicName);
      }
    }
    socket.topics.clear();
  });
});

httpServer.listen(0, "127.0.0.1", () => {
  const address = httpServer.address();
  if (address === null || typeof address === "string") {
    throw new Error("server did not bind to a TCP port");
  }
  console.log(JSON.stringify({ type: "ready", port: address.port }));
});

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk: string) => {
  for (const line of chunk.split("\n")) {
    if (line.trim() === "shutdown") {
      websocketServer.close(() => {
        httpServer.close(() => process.exit(0));
      });
    }
  }
});
