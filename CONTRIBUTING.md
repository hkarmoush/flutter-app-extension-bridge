# Contributing to `extension_bridge`

Thank you for your interest in contributing to **`extension_bridge`**—the type-safe, zero-`MethodChannel` cross-process IPC, lock-free storage engine, and code generator for Flutter ↔ iOS/macOS App Extensions.

Because `extension_bridge` operates at the boundary between the **Dart VM (`dart:ffi`)**, the **Darwin Kernel (`<notify.h>`, APFS `clonefile(2)`)**, and **Swift 6 Concurrency**, we maintain rigorous engineering, testing, and documentation standards. This guide covers everything you need to navigate the monorepo, make changes safely, and run our 6-Tier Verification Matrix.

---

## Table of Contents
1. [Prerequisites & Environment Setup](#1-prerequisites--environment-setup)
2. [Monorepo Architecture & Package Map](#2-monorepo-architecture--package-map)
3. [Core Systems Invariants (Must-Read Before Coding)](#3-core-systems-invariants-must-read-before-coding)
4. [Development Workflows](#4-development-workflows)
   - [Modifying the Wire Protocol or Storage Engine (Dart ↔ Swift)](#41-modifying-the-wire-protocol-or-storage-engine-dart--swift)
   - [Adding a New Schema Annotation or Codegen Feature](#42-adding-a-new-schema-annotation-or-codegen-feature)
   - [Adding or Modifying CLI Diagnostics (`EB-GEN-*` & `EB-DOC-*`)](#43-adding-or-modifying-cli-diagnostics-eb-gen---eb-doc-)
5. [Running the 6-Tier Testing & Verification Matrix](#5-running-the-6-tier-testing--verification-matrix)
6. [Code Style, FFI Memory Safety & Swift 6 Concurrency Rules](#6-code-style-ffi-memory-safety--swift-6-concurrency-rules)
7. [Documentation Standards & Gates](#7-documentation-standards--gates)
8. [Pull Request Checklist](#8-pull-request-checklist)

---

## 1. Prerequisites & Environment Setup

| Tool | Minimum Version | Purpose |
|---|---|---|
| **macOS** | macOS 14.0+ (Sonoma / Sequoia) | Required for Darwin `<notify.h>`, APFS `clonefile(2)`, and Xcode toolchain |
| **Dart SDK** | `>=3.6.0 <4.0.0` | Dart Workspace monorepo support, `extension type`, and `NativeCallable` FFI |
| **Flutter SDK** | `>=3.27.0` | Swift Package Manager plugin integration & `example/` host app |
| **Xcode & Swift** | Xcode 16.0+ / Swift 6.0+ | `swift-tools-version: 6.0` strict concurrency, iOS 17 `AppIntents`, iOS 18 `ControlWidget` |

### Bootstrap the Workspace
`extension_bridge` uses a native **Dart 3.6+ Workspace** (`resolution: workspace` in the root `pubspec.yaml`), so a single `dart pub get` at the root resolves all packages:

```bash
# 1. Resolve all Dart packages across the monorepo
dart pub get

# 2. Verify static analysis (including 100% public API doc checks)
dart analyze

# 3. Verify the standalone Swift 6 core runtime
cd swift/ExtensionBridgeCore && swift test && cd ../..
```

---

## 2. Monorepo Architecture & Package Map

```text
flutter-app-extension-bridge/
├── packages/
│   ├── extension_bridge_annotation/   # Zero-dependency schema annotations (@AppGroupSchema, @SharedState, etc.)
│   ├── extension_bridge/              # Dart FFI runtime (<notify.h>, clonefile, lock-free OCC store, Maildir queue)
│   └── extension_bridge_generator/    # Analyzer AST parser, Dart/SwiftPM emitters, and CLI (generate | doctor | sim)
├── swift/
│   └── ExtensionBridgeCore/           # Pure Swift 6 mirror of the runtime (used by App Extensions & SwiftPM targets)
├── benchmarks/
│   └── chaos_multiprocess_suite/      # Jepsen-style 5-process (4 Swift + 1 Dart) contention & SIGKILL chaos suite
├── example/                           # "PulseHub" showcase app (Flutter + Widget + Share + LiveActivity + ControlWidget)
└── doc/                               # ADRs, Framework Cookbooks, CLI Reference, and Error Code Encyclopedia
```

### Dependency & Data Flow Rules
1. **`extension_bridge_annotation` must remain 100% dependency-free.** It is imported by user schema files and application code.
2. **`extension_bridge` must remain a 100% pure Dart package (`sdk: ^3.6.0`, zero `sdk: flutter` dependency).** It resolves App Group container paths and foreground resume notifications directly via `libobjc.A.dylib` (`objc_msgSend`) and Darwin `<notify.h>`, allowing `dart test`, `dart run` CLI tools, background Dart Isolates, and Flutter iOS/macOS apps to use the exact same package without `dart:ui` lock-in.
3. **`extension_bridge` (Dart) and `ExtensionBridgeCore` (Swift) must maintain strict wire-format parity.** Any change to the 64-bit `<notify.h>` register bit layout (`[16-bit Magic 0xEB42 | 16-bit Logical Writer ID | 32-bit Generation]`), the JSON state envelope (`_eb_magic`, `_schema_version`, `_gen`, `_updated_at_us`, `_writer_id`), the `.cas` symlink lease format (`<pid>:<ts_us>:<uuid>`), or the Maildir queue filename format (`<hlc_ts>_<uuid>.json`) must be updated and unit-tested in **both** Dart and Swift simultaneously.
4. **Dogfooding Rule:** Never hand-write bridge boilerplate in `benchmarks/` or `example/`. Always edit the `.dart` schema and run `dart run extension_bridge generate`.

---

## 3. Core Systems Invariants (Must-Read Before Coding)

Before modifying the storage or notification layers, keep these three non-negotiable Darwin systems invariants in mind:

1. **Never Hold Kernel File Locks in the App Group Container (`0xdead10cc` Prevention):**
   - Do **not** use `flock(2)`, `fcntl(2)` advisory locks, `NSFileCoordinator`, or SQLite WAL locks inside the shared container. If SpringBoard suspends a process holding a kernel lock in a shared container, iOS terminates the process with `0xdead10cc`.
   - All reads must be **zero-lock snapshot reads** against immutable files placed via atomic POSIX `rename(2)` (prefaced by the two-stage `notify_check` ~299 ns shared-memory fast path → `notify_get_state` ~9.3 µs check).
   - All mutations (`write()` and `update()`) must serialize `.tmp.<uuid>` **before** acquiring the atomic `.cas` symlink lease (`symlink("<pid>:<ts_us>:<uuid>", ".<key>.v1.cas")`), probe `kill(holderPid, 0) == ESRCH` for instant dead-process eviction, and verify lease-token ownership before `rename(2)` and `unlink(2)`.
2. **Respect the 16–30 MB App Extension Jetsam Memory Ceiling:**
   - Never buffer large media files into memory (`Uint8List` / `Data`) or encode binary blobs as Base64 inside JSON envelopes.
   - Always route file attachments through `@SharedAttachment` using APFS `clonefile(2)` with `CLONE_NOOWNERCOPY` (and chunked streaming fallback on `EXDEV`), and garbage-collect `@SharedState` blobs from generations `< currentGen - 2`.
3. **Zero `MethodChannel` on the Data Path:**
   - All state reads, writes, queue drains, and `<notify.h>` signals must work in pure `dart:ffi` so they can execute on background Dart Isolates and standalone `dart test` processes without a running `FlutterEngine`.

---

## 4. Development Workflows

### 4.1 Modifying the Wire Protocol or Storage Engine (Dart ↔ Swift)
1. Update the Dart implementation under `packages/extension_bridge/lib/src/protocol/` or `storage/`.
2. Update the mirrored Swift 6 implementation under `swift/ExtensionBridgeCore/Sources/ExtensionBridgeCore/`.
3. Add corresponding Tier 1 (unit) and Tier 2 (fault-injection) tests in both `packages/extension_bridge/test/` and `swift/ExtensionBridgeCore/Tests/`.
4. Run the cross-language interop test suite to prove Dart writers and Swift readers (and vice versa) remain 100% compatible.

### 4.2 Adding a New Schema Annotation or Codegen Feature
1. **Annotation:** Add or update the annotation class in `packages/extension_bridge_annotation/lib/src/` with complete `{@template}` doc comments and an example snippet.
2. **AST Parser & Validator:** Update `packages/extension_bridge_generator/lib/src/parser/` to parse the annotation and validate constraints. If invalid usage is possible, assign a new `[EB-GEN-xxx]` code and add a negative test.
3. **Dart Emitter & `Fake*Bridge`:** Update `dart_emitter.dart`. Ensure that any new capability added to the real generated bridge is **also** implemented in the generated `Fake<Name>Bridge` class so Tier 4 contract parity tests pass.
4. **SwiftPM Emitter:** Update `swift_pm_emitter.dart`. Ensure generated Swift code compiles cleanly under Swift 6 strict concurrency (`Sendable`) and includes Swift-DocC `///` comments.
5. **Golden & Compiler Tests:** Run `dart test` in `packages/extension_bridge_generator` (which automatically invokes `swift build` on the generated Swift package).

### 4.3 Adding or Modifying CLI Diagnostics (`EB-GEN-*` & `EB-DOC-*`)
Every user-facing error emitted by `extension_bridge generate` or `extension_bridge doctor` must:
1. Have a unique, stable identifier (`EB-GEN-001`..`099` for generator errors; `EB-DOC-001`..`099` for Xcode/entitlement doctor errors).
2. Have a corresponding section in [`doc/troubleshooting/error-codes.md`](doc/troubleshooting/error-codes.md) explaining:
   - **What triggered the error**
   - **Why it matters (the underlying iOS/Flutter system constraint)**
   - **Exact step-by-step fix**
3. Be covered by an automated test in `packages/extension_bridge_generator/test/` (Tier 3 or Tier 6).

---

## 5. Running the 6-Tier Testing & Verification Matrix

We require all 6 tiers to pass before merging changes:

```bash
# Tier 1 & Tier 2: Dart Bit-Level Unit Tests & Deterministic POSIX Fault-Injection Suite
dart test packages/extension_bridge

# Tier 1 & Tier 2 (Swift Mirror): Swift 6 Core Runtime Unit & Fault-Injection Suite
cd swift/ExtensionBridgeCore && swift test && cd ../..

# Tier 3, Tier 4 & Tier 6: AST Parser, Golden Snapshots, Live Swift 6 Build Gate,
# Fake*Bridge Contract Parity Suite, and CLI (doctor / sim / generate) Tests
dart test packages/extension_bridge_generator

# Tier 5: Jepsen-Style 5-Process Chaos & Latency Benchmark (4 Swift Workers + 1 Dart VM)
dart run benchmarks/chaos_multiprocess_suite/bin/run_chaos.dart

# Example App Unit/Widget Tests (via FakePulseHubBridge) & Xcode Doctor Verification
cd example && flutter test && cd ..
dart run extension_bridge_generator:extension_bridge doctor --project example/ios --strict
```

---

## 6. Code Style, FFI Memory Safety & Swift 6 Concurrency Rules

### Dart & `dart:ffi` Guidelines
- **Zero-Cost Wrappers:** Prefer `extension type const` for 64-bit bitfields, notification tokens, and file descriptors.
- **Scoped Native Allocations:** Always use `using((Arena arena) { ... })` from `package:ffi` for temporary native pointers (`Pointer<Utf8>`, `Pointer<Uint64>`, `Pointer<Int32>`). Never leave raw `malloc`/`calloc` calls un-scoped.
- **Shared `_NSConcreteGlobalBlock` Dispatch & `NativeFinalizer`:** `notify_register_dispatch` requires an Objective-C Block (`void (^)(int)`), not a C function pointer. Always route dispatch registrations through the shared static `_NSConcreteGlobalBlock` `Block_layout` demultiplexer (`keepIsolateAlive = false`) and attach a `NativeFinalizer` bound to `notify_cancel` (ensuring the `NativeCallable` closure never captures a strong reference to the `Finalizable` token wrapper).
- **Strict Lints:** The workspace enforces `strict-casts: true`, `strict-inference: true`, `strict-raw-types: true`, and `public_member_api_docs: true`. Do not use `// ignore:` without an accompanying explanation of why it is unavoidable.

### Swift 6 Guidelines
- **Strict Concurrency & Cross-Platform Guards:** All targets compile with `swift-tools-version: 6.0`. All public structs, enums, and bridge controllers must conform to `Sendable`. Always guard iOS-only frameworks (`#if canImport(ActivityKit) && os(iOS)`, `#if os(iOS)` for `performExpiringActivity`) so generated packages and `ExtensionBridgeCore` compile cleanly under `swift build` / `swift test` on macOS.
- **Custom `Codable` Synthesis for Schema Evolution:** Do not rely on compiler-synthesized `Codable` for `@BridgeModel` structs or enums; always emit explicit `init(from decoder:)` and `encode(to encoder:)` implementations to support `@Default(...)`, `@DefaultEnumValue()`, UTC microsecond `Date` serialization, and `TimeInterval` seconds conversion.
- **Error Handling:** Never use `try!` or `fatalError` in runtime code (extensions crash silently or ruin user widgets). Always throw typed `ExtensionBridgeError` cases and handle corrupt/missing files gracefully via self-healing fallback.

---

## 7. Documentation Standards & Gates

In `extension_bridge`, documentation is verified alongside code:
1. **100% Public API Docs:** Every public class, method, getter, enum value, and constructor in Dart and Swift must have a `///` doc comment. Missing doc comments will fail `dart analyze`.
2. **Generated Code Quality:** When modifying `dart_emitter.dart` or `swift_pm_emitter.dart`, ensure the generated `.g.dart` and `.swift` files pass `dart analyze` (with `public_member_api_docs: true`) and include latency/lifecycle notes.
3. **Validate Documentation Links:** Run `dart doc --validate-links` before submitting your PR to ensure no broken cross-references exist.

---

## 8. Pull Request Checklist

Before opening or marking a Pull Request ready for review, verify that:
- [ ] `dart analyze` exits with `0` warnings and `0` errors across the workspace.
- [ ] `dart test` passes across all Dart packages (`extension_bridge`, `extension_bridge_generator`).
- [ ] `swift test` passes in `swift/ExtensionBridgeCore`.
- [ ] The Tier 5 Multi-Process Chaos Suite (`benchmarks/chaos_multiprocess_suite`) passes with **0 lost updates**, **0 torn reads**, **0 echo wakeups**, and **P50 wakeup < 400 µs**.
- [ ] Any new diagnostic code (`EB-GEN-*` or `EB-DOC-*`) is documented in `doc/troubleshooting/error-codes.md`.
- [ ] Relevant ADRs (`doc/architecture/`), guides (`doc/guides/`), or reference docs (`doc/reference/`) have been updated.
