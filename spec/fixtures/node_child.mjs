// spec/fixtures/node_child.mjs
process.on("message", (message) => {
	if (message?.chord2control?.type === "shutdown") process.exit(0);
	if (message?.chord2control?.type === "init") process.send({ chord2: { t: "pong", n: message.chord2control.value.n } });
	if (message?.chord2?.t === "ping") process.send({ chord2: { t: "pong", n: message.chord2.n + 1 } });
});
process.send({ chord2control: { type: "ready" } });
