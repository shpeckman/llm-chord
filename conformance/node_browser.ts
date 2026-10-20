// conformance/node_browser.ts
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Type } from "typebox";

const chord = await import(process.env.CHORD_SRC ?? "../../pi/packages/chord/src/index.ts");
const { createHost, hostNamed, method, remote, webSocketLink } = chord;

const Board = remote("t.conformance-board", {
	version: 1,
	input: Type.Object({}),
	host: hostNamed("server"),
	variants: {
		main: {
			state: { notes: Type.Array(Type.String()) },
			methods: { add: method(Type.String()), who: method(undefined, Type.Unknown()) },
		},
	},
});

const server = spawn(process.env.CRYSTAL_SERVER ?? "./crystal_server", [], { stdio: ["ignore", "pipe", "inherit"] });
const port = await new Promise<number>((resolve) =>
	server.stdout.on("data", (chunk: Buffer) => {
		const match = /listening (\d+)/.exec(chunk.toString());
		if (match) resolve(Number(match[1]));
	}),
);
const browser = createHost({
	self: { kind: "host" },
	name: "browser",
	kind: "client",
	upstream: { link: webSocketLink(new WebSocket(`ws://127.0.0.1:${port}/?token=ok`) as never), principal: { kind: "server" } },
	onError: (error: unknown) => console.error(error),
});
const board = browser.hold(Board, {});
await board.add("hello");
assert.deepEqual(await board.who(), { guest: "web" });
for (let i = 0; i < 100 && (board.notes.value as string[] | undefined)?.length !== 1; i++)
	await new Promise((resolve) => setTimeout(resolve, 10));
assert.deepEqual(board.notes.value, ["hello"]);
const big = "x".repeat(70 * 1024);
await board.add(big);
for (let i = 0; i < 100 && (board.notes.value as string[] | undefined)?.length !== 2; i++)
	await new Promise((resolve) => setTimeout(resolve, 10));
assert.deepEqual(board.notes.value, ["hello", big]);
await browser.close();
server.kill();
console.log("node browser <-> crystal server over WebSocket: ok");
