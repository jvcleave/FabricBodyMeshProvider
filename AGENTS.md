# Fabric Body Mesh Provider Engineering Guidance

Review `README.md` and `PLUG_IN_PLAN.md` before making changes. This repository
is a Fabric plug-in developed against the adjacent Fabric checkout; it is not a
CMResearchKit target.

## Project boundaries

- Use Swift 5.9 and target macOS 15 or later.
- Do not introduce third-party frameworks without asking first.
- Keep `BodyMeshProviderCore` independent of Fabric, Satin, SwiftUI, and
  CMResearchKit.
- Keep Fabric registration, node ports, settings, lifecycle, and Satin geometry
  adaptation in the plug-in target.
- CMResearchKit is a reference implementation and asset producer, not a source
  or binary dependency.
- Treat `frames.bin` and the mesh-constants format as strict, versioned external
  contracts. Reject incompatible or malformed data explicitly.
- Do not commit local `SampleData`, derived build output, or other unreviewed
  assets. The reviewed `LocalAssets/CoMotionMeshConstants.bin` is intentionally
  tracked and is part of the plug-in's source distribution.
- Preserve the constants file's documented size and SHA-256 digest. Treat any
  replacement as an explicit asset-format and distribution review.

## Fabric plug-in contract

- Build against the adjacent Fabric checkout by default. Respect
  `FABRIC_SOURCE_ROOT` when a different checkout is supplied.
- The plug-in entry point must do no archive loading, constants parsing, or mesh
  reconstruction during discovery.
- `BodyMeshProviderNode` inherits directly from `Node`: Fabric's current
  `BaseGeometryNode` is public but not open to external plug-ins.
- Keep node metadata and registered port names stable. Registration remains the
  source of truth for port type and order.
- Use `ParameterPort` for adjustable inputs and seed values through their Satin
  parameters.
- Source selection belongs in Codable settings. A settings change must not alter
  port type or count.
- Preserve one `BodyMeshGeometry` identity for the node lifetime and force-send
  that stable reference only when its content or primitive changes.
- Keep the current exact synchronous frame behavior until profiling justifies a
  documented scheduling change. Exported and interactive evaluation must return
  the frame requested by Fabric.
- Report user-data and runtime failures as recoverable `FabricError` values with
  focused messages. Do not crash or silently interpret a different format.
- Keep one node class per file.

## Swift style

- Prefer explicit, imperative control flow. Mutations should be obvious and
  local rather than hidden in fluent chains.
- Prefer `switch` when branching repeatedly on one value. Prefer `if`/`else` for
  genuine two-way branching.
- Use descriptive identifiers derived from the value or collection. Do not use
  single-letter, acronym-style, or generic loop names such as `vm`, `item`, or
  `obj`.
- Do not add extensions to types owned by this repository. Extensions are for
  types the project does not own.
- Avoid trivial private helpers called only once. Keep a helper when it names a
  meaningful lifecycle, validation, resource, or test boundary.
- Use underscore prefixes only when required by Swift or for a private backing
  property exposed through a public getter.
- Keep a single-parameter function signature or single-argument call on one line
  when it fits. Use multiline formatting for two or more parameters or arguments.
- Keep assignments on one line when the value fits without harming readability.
- Avoid semantic prepositions in external parameter labels. Encode the operation
  in the function name and keep internal parameter names descriptive.
- Prefer modern Swift and Foundation APIs, including `URL.appending(path:)` and
  Swift-native string operations.
- Avoid force unwraps and `try!` except for a documented, unrecoverable
  developer-owned construction invariant.
- Do not create fallback behavior solely for convenience. A fallback must be an
  explicit product rule.

## SwiftUI and presentation

- Use SwiftUI for plug-in settings; do not introduce AppKit unless requested or
  required by a documented framework boundary.
- Keep views thin. They own layout, styling, focus, and short-lived interaction
  state, while domain validation, archive work, reconstruction, and persistence
  remain outside the view.
- Views must not access engines, services, managers, or their singletons
  directly.
- Keep sorting, filtering, grouping, formatting, and other domain-data shaping
  out of `View.body`.
- Prefer focused concrete `View` types over computed view properties or private
  `@ViewBuilder` helpers for meaningful sections.
- Use semantic button actions. Do not use `.onChange` as a state synchronization
  bus.
- Prefer the Observation framework for new observable presentation state.
- Mark every `@Observable` presentation class `@MainActor` and use
  `@ObservationIgnored` for dependencies, caches, task handles, callbacks, and
  bookkeeping that should not invalidate the UI.
- Introduce `@Bindable` only at a control that needs a binding. A view that owns
  an observable view model stores it with `@State`; a view that receives one
  stores it as a plain property.
- Keep high-frequency playback and geometry state out of broad Observation.

## Engine, concurrency, and resource ownership

- Core requests, results, snapshots, and models should be value types and
  `Sendable` when they cross isolation boundaries.
- Do not put file I/O, archive validation, Accelerate reconstruction, or render
  work on `MainActor`.
- Every mutable asynchronous engine must choose and document one isolation
  strategy: actor, serial queue, lock, or dedicated processing thread.
- Never hold a lock across `await`, expensive reconstruction, a callback into
  unknown code, or Metal command submission.
- Treat `@unchecked Sendable` as a synchronization promise, never as a compiler
  workaround.
- The owner that creates a file mapping, task, buffer, or geometry resource owns
  its cleanup. Cleanup must be explicit and idempotent.
- Keep critical source identity separate from ordinary playback time. A new time
  tick does not invalidate otherwise compatible source data; a folder,
  descriptor, or constants change does.
- If frame work later becomes asynchronous, allow at most one active frame and
  one newest pending frame. Let valid active work finish, replace only the
  pending request, and resolve every superseded request exactly once.
- If derived-resource preparation later becomes asynchronous, use strict
  latest-generation publication: obsolete work may finish safely but must not
  replace a resource produced for the current source generation.
- Reuse buffers and fixed topology in changing-frame paths. Unchanged frame and
  selection inputs must perform no reconstruction or geometry rebuild.

## Testing and verification

- Test `BodyMeshProviderCore` independently from Fabric.
- Keep generated fixtures small. Exercise local ignored SampleData when present,
  and skip those integration checks cleanly when it is absent.
- Cover incompatible versions, malformed offsets, truncation, invalid counts,
  non-finite values, constants validation, topology bounds, and finite normalized
  reconstruction output.
- Verify first, middle, and last random-access frames for every locally installed
  sample archive.
- Build both Debug and Release plug-in configurations for release-oriented work.
- Use the same configuration for Fabric and the plug-in during runtime testing.
- Verify the installed bundle's code signature, manifest, resource presence, and
  constants digest.
- Restart Fabric after rebuilding because its node registry discovers external
  plug-ins during startup.
- Before committing, verify that ignored archives are not staged, that the
  tracked constants match their documented digest, and that no other
  unexpectedly large file is tracked.

## Git

- Keep changes surgical and preserve unrelated work in the adjacent Fabric
  checkout.
- Do not hard-wrap commit messages.
- Do not add a co-authorship signature. Append a final `Via <model>` line.
