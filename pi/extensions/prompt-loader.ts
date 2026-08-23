import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

type ToolPromptText = {
	description?: string;
	promptSnippet?: string;
	promptGuidelines?: string[];
};

type ToolPromptMap = Record<string, ToolPromptText>;

const extensionDir = dirname(fileURLToPath(import.meta.url));
const cache = new Map<string, ToolPromptMap>();

export function loadToolPrompts(fileName: string): ToolPromptMap {
	const cached = cache.get(fileName);
	if (cached) {
		return cached;
	}

	const path = join(extensionDir, "..", "prompts", fileName);
	const raw = readFileSync(path, "utf8");
	const parsed = JSON.parse(raw) as ToolPromptMap;
	cache.set(fileName, parsed);
	return parsed;
}

export function getToolPrompt(prompts: ToolPromptMap, toolName: string): ToolPromptText {
	return prompts[toolName] || {};
}
