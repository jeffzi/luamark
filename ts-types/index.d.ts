/** @noSelfInFile */
/// <reference types="@typescript-to-lua/language-extensions" />

declare module "luamark" {
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

  interface Result<
    P extends Record<string, string | number | boolean> = Record<string, string | number | boolean>,
  > extends BaseStats {
    readonly name: string;
    readonly rounds: number;
    readonly iterations: number;
    readonly timestamp: string;
    readonly unit: "s" | "kb";
    readonly ops?: number;
    readonly is_approximate?: boolean;
    readonly params: P;
  }

  interface Options<Ctx = unknown> {
    rounds?: number;
    time?: number;
    setup?: (this: void) => Ctx;
    teardown?: (this: void, ctx: Ctx) => void;
  }

  interface SuiteOptions<
    Ctx = unknown,
    P extends Record<string, string | number | boolean> = Record<string, string | number | boolean>,
  > {
    rounds?: number;
    time?: number;
    setup?: (this: void, params: P) => Ctx;
    teardown?: (this: void, ctx: Ctx, params: P) => void;
    params?: { [K in keyof P]: P[K][] };
  }

  interface Spec<
    Ctx = unknown,
    P extends Record<string, string | number | boolean> = Record<string, string | number | boolean>,
  > {
    fn: (this: void, ctx: Ctx, params: P) => void;
    // biome-ignore lint/suspicious/noConfusingVoidType: models Lua's `before(ctx, p) or ctx` — void means "no new ctx"
    before?: (this: void, ctx: Ctx, params: P) => Ctx | void;
    after?: (this: void, ctx: Ctx, params: P) => void;
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
  function timeit<Ctx = unknown>(
    this: void,
    fn: NoInfer<(this: void, ctx: Ctx) => void>,
    opts?: Options<Ctx>,
  ): Stats;

  function memit<Ctx = unknown>(
    this: void,
    fn: NoInfer<(this: void, ctx: Ctx) => void>,
    opts?: Options<Ctx>,
  ): Stats;

  function compare_time<
    Ctx = unknown,
    P extends Record<string, string | number | boolean> = Record<string, string | number | boolean>,
  >(
    this: void,
    funcs: NoInfer<Record<string, ((this: void, ctx: Ctx, params: P) => void) | Spec<Ctx, P>>>,
    opts?: SuiteOptions<Ctx, P>,
  ): Result<P>[];

  function compare_memory<
    Ctx = unknown,
    P extends Record<string, string | number | boolean> = Record<string, string | number | boolean>,
  >(
    this: void,
    funcs: NoInfer<Record<string, ((this: void, ctx: Ctx, params: P) => void) | Spec<Ctx, P>>>,
    opts?: SuiteOptions<Ctx, P>,
  ): Result<P>[];

  function Timer(this: void): Timer;

  function render(
    this: void,
    results: Stats | Result[],
    short?: boolean,
    max_width?: number,
  ): string;

  function humanize_time(this: void, s: number): string;

  function humanize_memory(this: void, kb: number): string;

  function humanize_count(this: void, n: number): string;

  function unload(this: void, pattern: string): number;
}
