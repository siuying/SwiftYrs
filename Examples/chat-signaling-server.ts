// Fixed-port y-webrtc signaling server for the ChatExample terminal chat.
//
// A pub/sub relay over WebSocket, mirroring yjs/y-webrtc bin/server.js (and the
// SwiftYrsWebRTC test server). Clients subscribe to room topics and publish
// announce/signal messages; the server forwards each publish to every
// subscriber of the topic. Binds to a fixed port (ws://127.0.0.1:4444 by
// default, override with PORT) so ChatExample can connect to it without
// discovery, and prints its ws:// URL on startup.
//
// Run with: node Examples/chat-signaling-server.ts

import { createServer } from "node:http";
import { WebSocketServer, type WebSocket } from "ws";

interface ConnData {
  topics: Set<string>;
}

type SignalingSocket = WebSocket & ConnData;

const host = "127.0.0.1";
const port = Number(process.env.PORT ?? 4444);

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

httpServer.listen(port, host, () => {
  console.log(`signaling server ready: ws://${host}:${port}`);
});
