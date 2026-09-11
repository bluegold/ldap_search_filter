export class ArgumentError extends Error { readonly _tag = "ArgumentError"; }
export class FilterError extends Error { readonly _tag = "FilterError"; }
export class InputError extends Error { readonly _tag = "InputError"; }
export class OutputError extends Error {
  readonly _tag = "OutputError";
  constructor(message: string, readonly code?: string) { super(message); }
}
