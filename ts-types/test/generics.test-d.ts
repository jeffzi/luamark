import { expectTypeOf } from "expect-type";
import type { Options, Result, Spec, Stats, SuiteOptions } from "luamark";
import { compare_memory, compare_time, memit, render, timeit } from "luamark";

// ---------------------------------------------------------------------------
// timeit / memit — Ctx inference from setup
// ---------------------------------------------------------------------------

// Ctx inferred as string[] from setup return type
timeit(
  (ctx) => {
    expectTypeOf(ctx).toEqualTypeOf<string[]>();
  },
  { setup: () => ["a", "b"] },
);

// Ctx defaults to unknown when no opts provided
timeit((ctx) => {
  expectTypeOf(ctx).toBeUnknown();
});

// memit infers Ctx the same way
memit(
  (ctx) => {
    expectTypeOf(ctx).toEqualTypeOf<number>();
  },
  { setup: () => 42 },
);

// teardown receives the same Ctx
timeit(() => {}, {
  setup: () => ({ count: 0 }),
  teardown: (ctx) => {
    expectTypeOf(ctx).toEqualTypeOf<{ count: number }>();
  },
});

// ---------------------------------------------------------------------------
// compare_time / compare_memory — Ctx + P inference
// ---------------------------------------------------------------------------

// P inferred from params config
const results = compare_time(
  { my_fn: (_ctx, params) => expectTypeOf(params.n).toBeNumber() },
  { params: { n: [10, 100] } },
);

// Result carries inferred P
expectTypeOf(results[0]!.params.n).toBeNumber();

// Ctx inferred from setup (no params → P defaults)
compare_time(
  {
    my_fn: (ctx) => {
      expectTypeOf(ctx).toEqualTypeOf<string[]>();
    },
  },
  { setup: () => ["a", "b"] },
);

// Both Ctx and P inferred together
compare_time(
  {
    my_fn: (ctx, params) => {
      expectTypeOf(ctx).toEqualTypeOf<number[]>();
      expectTypeOf(params.n).toBeNumber();
    },
  },
  {
    params: { n: [10, 100] },
    setup: () => [1, 2, 3],
  },
);

// compare_memory works the same way
compare_memory(
  { my_fn: (_ctx, params) => expectTypeOf(params.label).toBeString() },
  { params: { label: ["a", "b"] } },
);

// ---------------------------------------------------------------------------
// Spec interface
// ---------------------------------------------------------------------------

// Spec with explicit generics
const spec: Spec<string[], { n: number }> = {
  fn: (ctx, params) => {
    expectTypeOf(ctx).toEqualTypeOf<string[]>();
    expectTypeOf(params.n).toBeNumber();
  },
  before: (ctx, params) => {
    expectTypeOf(ctx).toEqualTypeOf<string[]>();
    expectTypeOf(params.n).toBeNumber();
    return ctx; // before can return Ctx
  },
  after: (ctx, _params) => {
    expectTypeOf(ctx).toEqualTypeOf<string[]>();
  },
  baseline: true,
};

// before can also return void (Lua: iteration_ctx = before(ctx, p) or ctx)
const _specVoidBefore: Spec<string[], { n: number }> = {
  fn: () => {},
  before: () => {}, // returns void — valid
};

// Spec used in compare functions
compare_time({ test: spec }, { params: { n: [1, 2, 3] }, setup: () => ["hello"] });

// ---------------------------------------------------------------------------
// Options / SuiteOptions interfaces
// ---------------------------------------------------------------------------

// Defaults work (Ctx = unknown, P = Record<string, string | number | boolean>)
const _defaultOpts: Options = { rounds: 10 };
const _defaultSuiteOpts: SuiteOptions = { rounds: 10 };

// Mapped params type: each key maps to an array of its value type
const _typedSuiteOpts: SuiteOptions<unknown, { n: number; label: string }> = {
  params: {
    n: [1, 2, 3],
    label: ["a", "b"],
  },
};

// Verify wrong element type is rejected
const _badParams: SuiteOptions<unknown, { n: number }> = {
  // @ts-expect-error — string[] is not assignable to number[]
  params: { n: ["not a number"] },
};

// ---------------------------------------------------------------------------
// render accepts Result[] with any P (covariant)
// ---------------------------------------------------------------------------

const typedResults: Result<{ n: number }>[] = [];
render(typedResults); // Result<{n: number}> assignable to Result (default P)

// render also accepts Stats
render({} as Stats);

// ---------------------------------------------------------------------------
// Result interface
// ---------------------------------------------------------------------------

// Result with default P
const defaultResult: Result = {} as Result;
expectTypeOf(defaultResult.params).toEqualTypeOf<Record<string, string | number | boolean>>();

// Result with specific P
const typedResult: Result<{ n: number }> = {} as Result<{ n: number }>;
expectTypeOf(typedResult.params.n).toBeNumber();
