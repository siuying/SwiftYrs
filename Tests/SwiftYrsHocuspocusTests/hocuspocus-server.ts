import { Server } from "@hocuspocus/server";

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

process.stdin.setEncoding("utf8");
process.stdin.on("data", async chunk => {
	const lines = chunk.split("\n");
	for (const line of lines) {
		if (line.trim() === "shutdown") {
			await server.destroy();
			process.exit(0);
		}
	}
});
