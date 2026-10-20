// conformance/node_parent.ts
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { Type } from "typebox";

const chord = await import(process.env.CHORD_SRC ?? "../../pi/packages/chord/src/index.ts");
const { createHost, hostNamed, ipcLink, method, remote } = chord;

const Counter = remote("t.conformance-counter", {
	version: 1,
	input: Type.Object({}),
	host: hostNamed("w1"),
	variants: {
		main: {
			state: { count: Type.Object({ n: Type.Number() }) },
			methods: { add: method(Type.Number(), Type.Number()), who: method(undefined, Type.Unknown()) },
		},
	},
});

const child = spawn(process.env.CRYSTAL_WORKER ?? "./crystal_worker", [], { stdio: ["ignore", "inherit", "inherit", "ipc"] });
const ready = new Promise<void>((resolve) =>
	child.on("message", (message: { chord2control?: { type: string } }) => {
		if (message?.chord2control?.type === "ready") resolve();
	}),
);
await ready;
const server = createHost({ self: { kind: "host" }, name: "server", onError: (error: unknown) => console.error(error) });
server.accept(ipcLink(child as never), { principal: { worker: "w1" }, kind: "host", name: "w1" });
const counter = server.hold(Counter, {});
const values: unknown[] = [];
counter.count.subscribe((value: unknown) => values.push(value));
assert.equal(await counter.add(2), 2);
assert.equal(await counter.add(3), 5);
assert.deepEqual(await counter.who(), { kind: "server" });
for (let i = 0; i < 100 && (counter.count.value as { n: number } | undefined)?.n !== 5; i++)
	await new Promise((resolve) => setTimeout(resolve, 10));
assert.deepEqual(counter.count.value, { n: 5 });
assert.deepEqual(values.at(-1), { n: 5 });
child.send({ chord2control: { type: "shutdown" } });
await new Promise<void>((resolve) => child.once("exit", () => resolve()));
await server.close();
console.log("node parent <-> crystal child over IPC: ok");
