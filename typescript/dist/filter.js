"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.parseFilter = parseFilter;
exports.evaluateFilter = evaluateFilter;
exports.inspectAttrs = inspectAttrs;
const ITEM_PARSER = /^([^~=><]+)(~=|>=|<=|=)(.+)$/;
const WILDCARD_MARK = "[:wildcard:]";
function escapeRegex(text) {
    return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function unescapeHex(text) {
    return text.replace(/\\([0-9a-fA-F]{2})/g, (_, hex) => String.fromCharCode(Number.parseInt(hex, 16)));
}
function splitTopLevel(expr) {
    const parts = [];
    let depth = 0;
    let start = 0;
    let sawParen = false;
    for (let i = 0; i < expr.length; i += 1) {
        const ch = expr[i];
        if (ch === "(") {
            if (depth === 0) {
                start = i + 1;
                sawParen = true;
            }
            depth += 1;
        }
        else if (ch === ")") {
            depth -= 1;
            if (depth < 0) {
                throw new Error("parenthesis mismatch");
            }
            if (depth === 0) {
                parts.push(expr.slice(start, i));
            }
        }
    }
    if (depth !== 0) {
        throw new Error("parenthesis mismatch");
    }
    return parts.length > 0 || sawParen ? parts : [expr];
}
function parseItem(expr) {
    const match = ITEM_PARSER.exec(expr);
    if (!match) {
        throw new Error("error in item syntax");
    }
    const [, attr, op, rawValue] = match;
    if (rawValue === "*") {
        return { kind: "item", attr, op, value: rawValue };
    }
    const value = unescapeHex(rawValue);
    const wildcardIndex = value.indexOf("*");
    const node = { kind: "item", attr, op, value };
    if (wildcardIndex >= 0) {
        const regexText = value
            .split("*")
            .map((part) => escapeRegex(part))
            .join(".*");
        node.regex = new RegExp(regexText);
    }
    return node;
}
function parseFilter(expr) {
    if (!expr) {
        throw new Error("empty filter");
    }
    if (expr[0] === "(") {
        const parts = splitTopLevel(expr);
        return parseFilter(parts[0]);
    }
    switch (expr[0]) {
        case "&":
            return { kind: "and", nodes: splitTopLevel(expr.slice(1)).map(parseFilter) };
        case "|":
            return { kind: "or", nodes: splitTopLevel(expr.slice(1)).map(parseFilter) };
        case "!": {
            const parts = splitTopLevel(expr.slice(1));
            if (parts.length !== 1) {
                throw new Error("not operator has more than one filter");
            }
            return { kind: "not", node: parseFilter(parts[0]) };
        }
        default:
            return parseItem(expr);
    }
}
function levenshtein(a, b) {
    const prev = new Array(b.length + 1).fill(0).map((_, i) => i);
    const curr = new Array(b.length + 1).fill(0);
    for (let i = 1; i <= a.length; i += 1) {
        curr[0] = i;
        for (let j = 1; j <= b.length; j += 1) {
            const cost = a[i - 1] === b[j - 1] ? 0 : 1;
            curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
        }
        for (let j = 0; j <= b.length; j += 1) {
            prev[j] = curr[j];
        }
    }
    return prev[b.length];
}
function evaluateFilter(node, attrs) {
    switch (node.kind) {
        case "and":
            return node.nodes.every((child) => evaluateFilter(child, attrs));
        case "or":
            return node.nodes.some((child) => evaluateFilter(child, attrs));
        case "not":
            return !evaluateFilter(node.node, attrs);
        case "item": {
            const actual = attrs[node.attr];
            if (node.op === "=") {
                if (node.value === "*") {
                    return Object.prototype.hasOwnProperty.call(attrs, node.attr);
                }
                if (node.regex) {
                    return typeof actual === "string" && node.regex.test(actual);
                }
                return actual === node.value;
            }
            if (node.op === "~=") {
                return typeof actual === "string" && levenshtein(node.value, actual) < 3;
            }
            if (node.op === ">=") {
                return typeof actual === "string" && actual >= node.value;
            }
            if (node.op === "<=") {
                return typeof actual === "string" && actual <= node.value;
            }
            throw new Error(`unsupported operator: ${node.op}`);
        }
    }
}
function escapeRubyString(text) {
    return JSON.stringify(text).slice(1, -1);
}
function formatKey(key) {
    return /^[A-Za-z_][A-Za-z0-9_]*$/.test(key)
        ? `:${key}=>`
        : `:${JSON.stringify(key)}=>`;
}
function formatValue(value) {
    if (value === null || value === undefined) {
        return "nil";
    }
    return `"${escapeRubyString(String(value))}"`;
}
function inspectAttrs(attrs) {
    const parts = Object.entries(attrs).map(([key, value]) => `${formatKey(key)}${formatValue(value)}`);
    return `{${parts.join(", ")}}`;
}
