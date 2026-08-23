import { Type } from "@sinclair/typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import net from "node:net";
import { getToolPrompt, loadToolPrompts } from "./prompt-loader";

type BridgeResult = {
	content: string;
	details?: Record<string, unknown>;
};

const SOCKET_PATH = process.env.MENTAT_EDITOR_BRIDGE_SOCKET;
const BRIDGE_HOST = process.env.MENTAT_EDITOR_BRIDGE_HOST;
const BRIDGE_PORT = process.env.MENTAT_EDITOR_BRIDGE_PORT ? Number(process.env.MENTAT_EDITOR_BRIDGE_PORT) : undefined;
const toolPrompts = loadToolPrompts("editor-tools.json");

function hasBridge(): boolean {
	return !!SOCKET_PATH || (!!BRIDGE_HOST && !!BRIDGE_PORT);
}

async function bridgeRequest(method: string, params: Record<string, unknown> = {}): Promise<BridgeResult> {
	if (!SOCKET_PATH && !(BRIDGE_HOST && BRIDGE_PORT)) {
		throw new Error("Mentat editor bridge is not configured.");
	}

	return await new Promise((resolve, reject) => {
		const socket = SOCKET_PATH
			? net.createConnection(SOCKET_PATH)
			: net.createConnection({
					host: BRIDGE_HOST,
					port: BRIDGE_PORT,
				});
		let buffer = "";
		let settled = false;

		const fail = (error: Error) => {
			if (settled) return;
			settled = true;
			socket.destroy();
			reject(error);
		};

		socket.on("error", (error) => fail(error));

		socket.on("connect", () => {
			socket.write(`${JSON.stringify({ method, params })}\n`);
		});

		socket.on("data", (chunk: Buffer | string) => {
			buffer += chunk.toString();
			const newline = buffer.indexOf("\n");
			if (newline === -1) return;

			const line = buffer.slice(0, newline);
			buffer = buffer.slice(newline + 1);

			try {
				const payload = JSON.parse(line) as { ok: boolean; result?: BridgeResult; error?: string };
				if (!payload.ok || !payload.result) {
					fail(new Error(payload.error || `Editor bridge request failed: ${method}`));
					return;
				}

				if (!settled) {
					settled = true;
					socket.end();
					resolve(payload.result);
				}
			} catch (error) {
				fail(error instanceof Error ? error : new Error(String(error)));
			}
		});

		socket.on("end", () => {
			if (!settled) {
				fail(new Error(`Editor bridge closed without responding to ${method}`));
			}
		});
	});
}

function textResult(result: BridgeResult) {
	return {
		content: [{ type: "text" as const, text: result.content }],
		details: result.details || {},
	};
}

function pathSchema(description: string) {
	return Type.Optional(
		Type.String({
			description,
		}),
	);
}

export default function mentatEditorTools(pi: ExtensionAPI) {
	const registeredToolNames = new Set<string>();
	const editorToolNames = [
		"read",
		"editor_context",
		"editor_visible_buffers",
		"editor_current_buffer",
		"editor_selection",
		"editor_diagnostics",
		"editor_lsp_hover",
		"editor_lsp_definition",
		"editor_lsp_references",
	] as const;

	function activateEditorTools() {
		const active = new Set(pi.getActiveTools());
		let changed = false;
		for (const name of editorToolNames) {
			if (!active.has(name)) {
				active.add(name);
				changed = true;
			}
		}
		if (changed) {
			pi.setActiveTools(Array.from(active));
		}
	}

	function registerEditorTool(definition: Parameters<ExtensionAPI["registerTool"]>[0]) {
		if (registeredToolNames.has(definition.name)) {
			return;
		}
		registeredToolNames.add(definition.name);
		pi.registerTool(definition);
	}

	function registerEditorTools() {
		registerEditorTool({
			name: "read",
			label: "read",
			...getToolPrompt(toolPrompts, "read"),
			parameters: Type.Object({
				path: pathSchema("Optional absolute or project-relative file path. Defaults to the current editor buffer."),
				offset: Type.Optional(Type.Number({ description: "1-indexed line number to start reading from." })),
				limit: Type.Optional(Type.Number({ description: "Maximum number of lines to read." })),
			}),
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("current_buffer", params as Record<string, unknown>));
			},
		});

		registerEditorTool({
			name: "editor_context",
			label: "Editor Context",
			...getToolPrompt(toolPrompts, "editor_context"),
			parameters: Type.Object({}),
			async execute() {
				return textResult(await bridgeRequest("context"));
			},
		});

		registerEditorTool({
			name: "editor_visible_buffers",
			label: "Visible Buffers",
			...getToolPrompt(toolPrompts, "editor_visible_buffers"),
			parameters: Type.Object({
				limit_per_buffer: Type.Optional(Type.Number({ description: "Maximum number of lines to read from each visible buffer. Defaults to 160." })),
				max_buffers: Type.Optional(Type.Number({ description: "Maximum number of visible buffers to inspect. Defaults to 6." })),
				include_current: Type.Optional(Type.Boolean({ description: "Include the current buffer in the result. Defaults to true." })),
			}),
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("visible_buffers", params as Record<string, unknown>));
			},
		});

		registerEditorTool({
			name: "editor_current_buffer",
			label: "Current Buffer",
			...getToolPrompt(toolPrompts, "editor_current_buffer"),
			parameters: Type.Object({
				path: pathSchema("Optional absolute or project-relative file path. Defaults to the current buffer."),
			}),
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("current_buffer", params as Record<string, unknown>));
			},
		});

		registerEditorTool({
			name: "editor_selection",
			label: "Editor Selection",
			...getToolPrompt(toolPrompts, "editor_selection"),
			parameters: Type.Object({
				path: pathSchema("Optional absolute or project-relative file path. Defaults to the current buffer."),
			}),
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("selection", params as Record<string, unknown>));
			},
		});

		registerEditorTool({
			name: "editor_diagnostics",
			label: "Editor Diagnostics",
			...getToolPrompt(toolPrompts, "editor_diagnostics"),
			parameters: Type.Object({
				path: pathSchema("Optional absolute or project-relative file path."),
			}),
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("diagnostics", params as Record<string, unknown>));
			},
		});

		const lspParameters = Type.Object({
			path: pathSchema("Optional absolute or project-relative file path. Defaults to the current buffer."),
			line: Type.Optional(Type.Number({ description: "1-indexed line number. Defaults to the cursor line for the current buffer." })),
			col: Type.Optional(Type.Number({ description: "1-indexed column number. Defaults to the cursor column for the current buffer." })),
		});

		registerEditorTool({
			name: "editor_lsp_hover",
			label: "LSP Hover",
			...getToolPrompt(toolPrompts, "editor_lsp_hover"),
			parameters: lspParameters,
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("lsp_hover", params as Record<string, unknown>));
			},
		});

		registerEditorTool({
			name: "editor_lsp_definition",
			label: "LSP Definition",
			...getToolPrompt(toolPrompts, "editor_lsp_definition"),
			parameters: lspParameters,
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("lsp_definition", params as Record<string, unknown>));
			},
		});

		registerEditorTool({
			name: "editor_lsp_references",
			label: "LSP References",
			...getToolPrompt(toolPrompts, "editor_lsp_references"),
			parameters: lspParameters,
			async execute(_toolCallId, params) {
				return textResult(await bridgeRequest("lsp_references", params as Record<string, unknown>));
			},
		});
	}

	function ensureEditorToolsActive() {
		registerEditorTools();
		activateEditorTools();
	}

	pi.registerCommand("editor-bridge", {
		description: "Show Mentat editor bridge status",
		handler: async (_args, ctx) => {
			ensureEditorToolsActive();
			const allTools = new Set(pi.getAllTools().map((tool) => tool.name));
			const activeTools = new Set(pi.getActiveTools());
			const available = editorToolNames.filter((name) => allTools.has(name));
			const active = editorToolNames.filter((name) => activeTools.has(name));
			const message = hasBridge()
				? `${SOCKET_PATH ? SOCKET_PATH : `${BRIDGE_HOST}:${BRIDGE_PORT}`}\nregistered: ${available.join(", ") || "none"}\nactive: ${active.join(", ") || "none"}`
				: "Mentat editor bridge is unavailable in this session";
			ctx.ui.notify(message, hasBridge() && active.length > 0 ? "info" : "warning");
		},
	});

	pi.on("session_start", async () => {
		ensureEditorToolsActive();
	});

	pi.on("session_switch", async () => {
		ensureEditorToolsActive();
	});

	pi.on("session_fork", async () => {
		ensureEditorToolsActive();
	});

	pi.on("session_tree", async () => {
		ensureEditorToolsActive();
	});

	registerEditorTools();
}
