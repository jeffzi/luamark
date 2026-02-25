/** @noSelfInFile */
/// <reference types="@typescript-to-lua/language-extensions" />

declare module "luamark" {
  type ParamValue = string | number | boolean;

  interface BaseStats {
    readonly median: number;
    readonly ci_lower: number;
    readonly ci_upper: number;
    readonly ci_margin: number;
    readonly total: number;
    readonly samples: readonly number[];
    readonly relative?: number;
    readonly rank?: number;
  }

  interface Stats extends BaseStats {
    readonly rounds: number;
    readonly iterations: number;
    readonly timestamp: string;
    readonly unit: "s" | "kb";
    readonly ops?: number;
    readonly is_approximate?: boolean;
  }

  interface Result extends BaseStats {
    readonly name: string;
    readonly rounds: number;
    readonly iterations: number;
    readonly timestamp: string;
    readonly unit: "s" | "kb";
    readonly ops?: number;
    readonly is_approximate?: boolean;
    readonly params: Record<string, ParamValue>;
  }

  interface Options {
    rounds?: number;
    time?: number;
    setup?: (this: void) => unknown;
    teardown?: (this: void, ctx?: unknown) => void;
  }

  interface SuiteOptions {
    rounds?: number;
    time?: number;
    setup?: (this: void, params: Record<string, ParamValue>) => unknown;
    teardown?: (this: void, ctx: unknown, params: Record<string, ParamValue>) => void;
    params?: Record<string, ParamValue[]>;
  }

  interface Spec {
    fn: (this: void, ctx?: unknown, params?: Record<string, ParamValue>) => void;
    before?: (this: void, ctx?: unknown, params?: Record<string, ParamValue>) => unknown;
    after?: (this: void, ctx?: unknown, params?: Record<string, ParamValue>) => void;
    baseline?: boolean;
  }

  interface Timer {
    start(this: void): void;
    stop(this: void): number;
    elapsed(this: void): number;
    reset(this: void): void;
  }

  // Mutable config
  let rounds: number;
  let time: number;

  // Readonly config
  const clock_name: string;
  const _VERSION: string;

  // Functions
  function timeit(
    this: void,
    fn: (this: void, ctx?: unknown, params?: Record<string, ParamValue>) => void,
    opts?: Options,
  ): Stats;

  function memit(
    this: void,
    fn: (this: void, ctx?: unknown, params?: Record<string, ParamValue>) => void,
    opts?: Options,
  ): Stats;

  function compare_time(
    this: void,
    funcs: Record<string, ((this: void, ctx?: unknown, params?: Record<string, ParamValue>) => void) | Spec>,
    opts?: SuiteOptions,
  ): Result[];

  function compare_memory(
    this: void,
    funcs: Record<string, ((this: void, ctx?: unknown, params?: Record<string, ParamValue>) => void) | Spec>,
    opts?: SuiteOptions,
  ): Result[];

  function Timer(this: void): Timer;

  function render(this: void, results: Stats | Result[], short?: boolean, max_width?: number): string;

  function humanize_time(this: void, s: number): string;

  function humanize_memory(this: void, kb: number): string;

  function humanize_count(this: void, n: number): string;

  function unload(this: void, pattern: string): number;
}
