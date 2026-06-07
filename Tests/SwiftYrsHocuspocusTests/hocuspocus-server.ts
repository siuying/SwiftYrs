import { Server } from "@hocuspocus/server";
import * as readline from "node:readline";

const authToken = process.env.HOCUSPOCUS_AUTH_TOKEN ?? null;

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
