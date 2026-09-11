import { Effect } from "effect";
export { FilterError } from "./errors";
import { FilterError } from "./errors";

export type AttrValue = string | null | undefined;
export type AttrMap = Record<string, AttrValue>;
export type Operator = "=" | "~=" | ">=" | "<=";
export type FilterNode =
  | { kind: "item"; attr: string; op: Operator; value: string; presence: boolean; regex?: RegExp }
  | { kind: "and"; nodes: FilterNode[] }
  | { kind: "or"; nodes: FilterNode[] }
  | { kind: "not"; node: FilterNode };

const asFilterError = (error: unknown): FilterError => error instanceof FilterError ? error : new FilterError(String(error));
const isOperatorStart = (char: string | undefined): boolean => char === "=" || char === "~" || char === ">" || char === "<";

function decodeValue(raw: string): { value: string; presence: boolean; regex?: RegExp } {
  const bytes: number[] = []; const segments: Uint8Array[] = []; let segment: number[] = []; let hasWildcard = false;
  for (let i = 0; i < raw.length;) {
    const char = raw[i];
    if (char === "\\") {
      const hex = raw.slice(i + 1, i + 3);
      if (!/^[0-9a-fA-F]{2}$/.test(hex)) throw new FilterError("invalid escape sequence");
      const byte = Number.parseInt(hex, 16); bytes.push(byte); segment.push(byte); i += 3;
    } else if (char === "*") {
      hasWildcard = true; segments.push(Uint8Array.from(segment)); segment = []; bytes.push(0x2a); i += 1;
    } else {
      const encoded = new TextEncoder().encode(char); bytes.push(...encoded); segment.push(...encoded); i += 1;
    }
  }
  let value: string;
  try { value = new TextDecoder("utf-8", { fatal: true }).decode(Uint8Array.from(bytes)); }
  catch { throw new FilterError("invalid UTF-8 escape sequence"); }
  if (!hasWildcard || raw === "*") return { value, presence: raw === "*" };
  segments.push(Uint8Array.from(segment));
  const parts = segments.map((part) => {
    try { return new TextDecoder("utf-8", { fatal: true }).decode(part).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); }
    catch { throw new FilterError("invalid UTF-8 escape sequence"); }
  });
  return { value, presence: false, regex: new RegExp(`^${parts.join(".*")}$`) };
}

class Parser {
  private position = 0;
  constructor(private readonly input: string) {}
  parse(): FilterNode { const node = this.filter(); if (!this.eof()) throw new FilterError("unexpected trailing input"); return node; }
  private filter(): FilterNode {
    this.expect("("); const node = this.content(); this.expect(")"); return node;
  }
  private content(): FilterNode {
    const marker = this.peek();
    if (marker === "&" || marker === "|") { this.position += 1; const nodes: FilterNode[] = []; while (this.peek() === "(") nodes.push(this.filter()); if (nodes.length === 0) throw new FilterError("operator requires at least one filter"); return marker === "&" ? { kind: "and", nodes } : { kind: "or", nodes }; }
    if (marker === "!") { this.position += 1; const node = this.filter(); if (this.peek() === "(") throw new FilterError("not operator has more than one filter"); return { kind: "not", node }; }
    if (marker === ")" || marker === undefined) throw new FilterError("empty filter");
    return this.item();
  }
  private item(): FilterNode {
    const start = this.position; while (!this.eof() && !isOperatorStart(this.peek()) && this.peek() !== "(" && this.peek() !== ")") this.position += 1;
    const attr = this.input.slice(start, this.position); if (!attr || this.peek() === "(") throw new FilterError("error in item syntax");
    const op = this.operator(); const valueStart = this.position; while (!this.eof() && this.peek() !== ")") { if (this.peek() === "(") throw new FilterError("error in item syntax"); this.position += 1; }
    if (this.eof()) throw new FilterError("parenthesis mismatch");
    const decoded = decodeValue(this.input.slice(valueStart, this.position)); return { kind: "item", attr, op, ...decoded };
  }
  private operator(): Operator {
    const first = this.peek(); if (first === "=") { this.position += 1; return "="; }
    if (first !== "~" && first !== ">" && first !== "<") throw new FilterError("error in item syntax");
    this.position += 1; if (this.peek() !== "=") throw new FilterError("error in item syntax"); this.position += 1; return `${first}=` as Operator;
  }
  private expect(char: string): void { if (this.peek() !== char) throw new FilterError("parenthesis mismatch"); this.position += 1; }
  private peek(): string | undefined { return this.input[this.position]; }
  private eof(): boolean { return this.position >= this.input.length; }
}

export const parseFilter = (expr: string): Effect.Effect<FilterNode, FilterError> => Effect.try({ try: () => new Parser(expr).parse(), catch: asFilterError });

function levenshtein(a: string, b: string): number {
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i); const curr = new Array<number>(b.length + 1).fill(0);
  for (let i = 1; i <= a.length; i += 1) { curr[0] = i; for (let j = 1; j <= b.length; j += 1) curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)); for (let j = 0; j <= b.length; j += 1) prev[j] = curr[j]; }
  return prev[b.length];
}

export function evaluateFilter(node: FilterNode, attrs: AttrMap): boolean {
  if (node.kind === "and") return node.nodes.every((child) => evaluateFilter(child, attrs));
  if (node.kind === "or") return node.nodes.some((child) => evaluateFilter(child, attrs));
  if (node.kind === "not") return !evaluateFilter(node.node, attrs);
  const actual = attrs[node.attr];
  if (node.op === "=") { if (node.presence) return Object.prototype.hasOwnProperty.call(attrs, node.attr); return node.regex ? typeof actual === "string" && node.regex.test(actual) : actual === node.value; }
  if (node.op === "~=") return typeof actual === "string" && levenshtein(node.value, actual) < 3;
  if (node.op === ">=") return typeof actual === "string" && actual >= node.value;
  if (node.op === "<=") return typeof actual === "string" && actual <= node.value;
  throw new FilterError(`unsupported operator: ${node.op}`);
}

export function inspectAttrs(attrs: AttrMap): string {
  const parts = Object.entries(attrs).map(([key, value]) => `${/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) ? `${key}: ` : `${JSON.stringify(key)} => `}${value === null || value === undefined ? "nil" : JSON.stringify(String(value))}`);
  return `{${parts.join(", ")}}`;
}
