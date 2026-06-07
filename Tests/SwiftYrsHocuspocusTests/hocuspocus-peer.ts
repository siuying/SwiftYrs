import { HocuspocusProvider } from "@hocuspocus/provider";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import * as readline from "node:readline";

const [url, name, token = ""] = process.argv.slice(2);
if (url === undefined || name === undefined) {
	throw new Error("usage: node hocuspocus-peer.ts <url> <name> [token]");
}
const document = new Y.Doc();
const awareness = new Awareness(document);
const text = document.getText("body");
const statelessMessages: string[] = [];

const provider = new HocuspocusProvider({
	url,
	name,
	document,
	awareness,
	token: token.length > 0 ? token : null,
	sessionAwareness: false,
	onSynced: ({ state }) => {
		if (state) {
			emit({ type: "synced" });
		}
	},
	onAuthenticated: ({ scope }) => emit({ type: "authenticated", scope }),
	onStateless: ({ payload }) => {
		statelessMessages.push(payload);
		emit({ type: "stateless", payload });
	},
});

function emit(value: unknown) {
	console.log(JSON.stringify(value));
}

function states() {
	return Array.from(awareness.getStates().entries()).map(([clientID, state]) => ({
		clientID,
		state,
	}));
}

emit({ type: "ready" });

const rl = readline.createInterface({ input: process.stdin });
rl.on("line", line => {
	const trimmed = line.trim();
	if (trimmed.length === 0) {
		return;
	}
	if (trimmed === "shutdown") {
		provider.destroy();
		emit({ type: "ok" });
		process.exit(0);
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
	case "setAwareness":
		awareness.setLocalState(command.state);
		emit({ type: "ok" });
		break;
	case "getAwareness":
		emit({ type: "awareness", states: states() });
		break;
	case "sendStateless":
		provider.sendStateless(command.payload);
		emit({ type: "ok" });
		break;
	case "getStateless":
		emit({ type: "statelessMessages", messages: statelessMessages });
		break;
	case "shutdown":
		provider.destroy();
		emit({ type: "ok" });
		process.exit(0);
	default:
		emit({ type: "error", message: `Unknown command: ${command.type}` });
	}
});
