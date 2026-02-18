# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v1.0.0] - 2026-02-17

### Changed

- `timeit`/`memit` now accept a single function only. Pass multiple functions
  to `compare_time`/`compare_memory` instead.
- `render(results, short?, max_width?)` replaces `summarize`.
- Simpler `rounds` and `time` options replace `min_rounds`, `max_rounds`,
  `max_iterations`, `warmups`.
- `max_time` renamed to `time`.
- Stats overhauled. Bootstrap confidence interval fields (`ci_lower`,
  `ci_upper`, `ci_margin`, `samples`) replace `count`, `min`, `max`, `mean`,
  `stddev`, `warmups`.
- `ratio` field renamed to `relative`; relative to an explicit baseline
  (`Spec.baseline`), or the fastest function by default.
- `setup`/`teardown` now run once per param combo and pass context:
  `setup(params?)` returns `ctx`, `fn(ctx, params)` receives it,
  `teardown(ctx, params)` cleans up.
- `before`/`after` hooks handle per-iteration work (formerly
  `setup`/`teardown`).
- Faster time measurement when hooks are absent.
- More accurate per-call memory measurements.

### Added

- `compare_time(funcs, opts?)` and `compare_memory(funcs, opts?)` for
  multi-function comparison.
- `Spec` type with per-function `before`/`after` hooks and `baseline` flag.
- `SuiteOptions.params` for parameterized benchmarks (cartesian product).
- Bootstrap confidence intervals for median.
- Shared ranks when confidence intervals overlap, with `is_approximate` flag.
- `ops` field (operations/sec) on time benchmark results.
- `render(results, short?, max_width?)` with full table and compact bar chart
  modes.
- `humanize_time(s)`, `humanize_memory(kb)`, `humanize_count(n)` formatting
  utilities.
- `Timer()` standalone timer object for ad-hoc profiling.
- `unload(pattern)` utility to remove modules from `package.loaded`.
- Validate that config values are positive numbers.
- Warning when only `os.clock` is available.

### Removed

- Luau support.
- Markdown output format.
- Allocspy support. Memory is now measured via `collectgarbage("count")`.

### Fixed

- JIT trace compilation no longer inflates measurements when hooks are present.
- Fix incorrect calibration scaling.

## [v0.9.1] - 2025-08-10

### Fixed

- Honor `disable_gc=false`.
- Avoid division by zero for single-sample standard deviation.
- Fix fast scale-up calibration not triggered.

## [v0.9.0] - 2025-01-05

### Added

- Markdown support via `luamark.summarize`.

## [v0.8.0] - 2024-12-25

### Added

- Expose configuration options.
- [Allocspy](https://github.com/siffiejoe/lua-allocspy) memory tracking.

### Fixed

- Fix fallback to default `os.clock` when higher precision clocks are
  unavailable.

## [v0.7.0] - 2024-05-03

### Added

- Luau support.

### Fixed

- Fix fallback to default `os.clock` when higher precision clocks are
  unavailable.

## [v0.6.0] - 2024-04-23

### Changed

- Rank results by median instead of mean.

## [v0.5.0] - 2024-03-15

### Changed

- Replace `print_summary` with `summarize`, which returns a string. The
  `__tostring` metamethod lets you write `print(results)` directly.
- Tweak result formatting: center and re-order headers.
- Display human-readable units. The results table retains seconds and kilobytes
  for flexibility.

### Fixed

- Sort ranks as numbers instead of lexical order.

## [v0.4.0] - 2024-02-02

### Removed

- `measure_time` and `measure_memory` from public API. `timeit` and `memit`
  cover the same usage.

### Fixed

- Run setup and teardown on every call, including during calibration.

## [v0.3.1] - 2024-02-01

### Added

- Setup and teardown arguments to `timeit` and `memit`.

### Fixed

- Remove duplicate total in stats table.

## [v0.3.0] - 2024-01-23

### Changed

- Restructure for usability and accuracy by supporting multiple Lua clock
  modules.

## [v0.2.0] - 2024-01-15

### Added

- Auto-discovery of `runs` arg.

### Changed

- Return stats instead of samples.

## [v0.1.0] - 2024-01-13

### Added

- Initial release. LuaMark is a portable microbenchmarking library for Lua that
  precisely measures execution time and memory usage.

[Unreleased]: https://github.com/jeffzi/luamark/compare/v1.0.0...HEAD
[v1.0.0]: https://github.com/jeffzi/luamark/compare/v0.9.1...v1.0.0
[v0.9.1]: https://github.com/jeffzi/luamark/compare/v0.9.0...v0.9.1
[v0.9.0]: https://github.com/jeffzi/luamark/compare/v0.8.0...v0.9.0
[v0.8.0]: https://github.com/jeffzi/luamark/compare/v0.7.0...v0.8.0
[v0.7.0]: https://github.com/jeffzi/luamark/compare/v0.6.0...v0.7.0
[v0.6.0]: https://github.com/jeffzi/luamark/compare/v0.5.0...v0.6.0
[v0.5.0]: https://github.com/jeffzi/luamark/compare/v0.4.0...v0.5.0
[v0.4.0]: https://github.com/jeffzi/luamark/compare/v0.3.1...v0.4.0
[v0.3.1]: https://github.com/jeffzi/luamark/compare/v0.3.0...v0.3.1
[v0.3.0]: https://github.com/jeffzi/luamark/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/jeffzi/luamark/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/jeffzi/luamark/releases/tag/v0.1.0
