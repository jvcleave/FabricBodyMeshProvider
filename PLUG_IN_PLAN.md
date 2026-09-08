# Body Mesh Provider Plugin Plan

## Goal

Allow a Fabric user to select a prepared CoMotion asset folder and produce a
time-varying Satin geometry that can be connected to Fabric's existing Mesh,
Material, camera, lighting, and rendering nodes.

The first release reads existing prepared data without importing or linking
CMResearchKit. A Body Mesh Intrinsic Camera is deferred to Phase 2.

## Agreed Product Boundary

- Keep Body Mesh Provider in its own repository and develop it against the
  adjacent Fabric checkout.
- Treat `frames.bin` as the required asset payload.
- Treat `asset.json` as optional descriptive and validation metadata.
- Ignore `thumbnail.jpg` during Phase 1.
- Reimplement only the versioned archive-reading and mesh-reconstruction subset
  needed by the plugin; do not import CMResearchKit.
- Output Satin geometry and let Fabric own materials, cameras, scene composition,
  and rendering.
- Support multiple detected people by merging the selected bodies into one
  geometry in Phase 1.
- Add a dedicated Body Mesh Intrinsic Camera node in Phase 2 rather than letting
  the geometry provider mutate Fabric's active camera.

## Source Data Contract

Phase 1 supports the current compact CoMotion archive contract:

- Archive format version: 2
- Mesh schema version: 1
- Model compatibility version: 2
- SMPL compatibility version: 1
- Maximum people per frame: 8
- Mesh topology: 6,890 vertices and 13,776 triangles per body
- Mesh parameters per body: confidence, shape coefficients, pose features,
  skinning transforms, and translation

The loader must reject unsupported versions, malformed offsets, truncated
records, invalid counts, non-finite values, and out-of-range triangle indices.
It must never silently interpret an incompatible archive.

The archive should be memory-mapped and indexed. Opening an asset may validate
the complete header and frame-offset table, but playback should decode only the
requested frame rather than constructing every frame in memory.

## Proposed Architecture

```text
Selected asset folder
        |
        v
CoMotion archive reader --------> asset metadata
        |
        v
Time-to-frame resolver
        |
        v
Body selection (confidence and maximum count)
        |
        v
Mesh and smooth-normal reconstruction
        |
        v
Stable dynamic Satin geometry
        |
        v
Fabric Mesh + Material + Camera + Renderer
```

### Core package

`BodyMeshProviderCore` contains no Fabric, Satin, SwiftUI, or application code.
It owns:

- Optional `asset.json` decoding.
- Version-2 archive validation and indexed frame reading.
- Immutable frame and body parameter models.
- Mesh-constants loading and validation.
- Vertex reconstruction using Accelerate and simd.
- Canonical smooth-normal preparation and per-frame normal skinning.
- Deterministic time-to-frame calculation.

The reviewed mesh constants are included at
`LocalAssets/CoMotionMeshConstants.bin`. Builds verify the documented byte count
and SHA-256 digest before copying them into the plug-in bundle.

### Fabric plugin target

The plugin target owns:

- Plugin registration.
- Node metadata, ports, serialization, and execution lifecycle.
- Folder-selection settings and runtime status presentation.
- Frame caching and coordination.
- Conversion from reconstructed body meshes into Satin vertex/index data.
- A stable dynamic geometry instance whose buffers change only when the
  presented frame changes.

The plugin entry point must perform no archive loading or reconstruction during
bundle discovery.

## Repository Structure

```text
BodyMeshProvider/
├── PLUG_IN_PLAN.md
├── README.md
├── .gitignore
├── BodyMeshProviderCore/
│   ├── Package.swift
│   ├── Sources/BodyMeshProviderCore/
│   │   ├── Archive/
│   │   ├── Reconstruction/
│   │   └── Resources/
│   └── Tests/BodyMeshProviderCoreTests/
├── BodyMeshProvider/
│   ├── BodyMeshProvider.xcodeproj
│   └── BodyMeshProvider/
│       ├── Plugin/
│       ├── Nodes/
│       ├── Geometry/
│       ├── Playback/
│       ├── Settings/
│       └── Info.plist
├── LocalAssets/
│   └── CoMotionMeshConstants.bin
└── SampleData/
```

`SampleData` remains local and ignored because the current collection is too
large for ordinary source control. Unit tests use small generated or trimmed
fixtures under the core package's test directory.

## Phase 1 Node Design

### Body Mesh Provider

- Node type: Geometry
- Execution mode: Provider
- Time mode: Time Base
- Base class: `BaseGeometryNode`, which owns the standard Primitive and Geometry
  ports and primitive conversion. The provider overrides throwing `execute()`,
  uses the inherited `evaluate()` bookkeeping, and publishes its stable geometry
  when its contents or primitive change.
- Stable name: `Body Mesh Provider`

The node uses a Codable `BodyMeshProviderSettings` value and provides a custom
initializer so procedural graph construction can select an asset without going
through the UI.

### Settings

- **Asset Folder:** Selects a directory containing `frames.bin`.
- The settings view shows the loaded asset name, compatibility status, native
  frame rate, frame count, duration, and the most recent loading error.

Changing the folder closes the previous mapping, clears frame caches, validates
the replacement, updates metadata outputs, and marks the node dirty. It must not
change the number or type of registered ports.

### Input ports

| Port | Type | Default | Meaning |
| --- | --- | --- | --- |
| Time | Float | Graph time when unconnected | Requested playback position in seconds |
| Loop | Bool | `true` | Wrap time at the archive duration |
| Playback Rate | Float | `1` | Multiplier applied only when Time is unconnected |
| Confidence | Float | `0.2` | Minimum accepted confidence, clamped to `0.05...1` |
| Maximum Bodies | Int | `1` | Maximum reconstructed bodies, clamped to `1...8` |

The inherited geometry primitive remains Triangle by default.

When Time is connected, its value is authoritative and Playback Rate does not
modify it. This allows Movie Provider's current-time output to drive the body
mesh without accumulating a second playback clock.

### Output ports

| Port | Type | Meaning |
| --- | --- | --- |
| Geometry | Geometry | Selected bodies merged into one indexed Satin geometry |
| Detected Bodies | Int | Valid bodies stored in the requested frame before filtering |
| Output Bodies | Int | Bodies included after confidence and maximum-count filtering |
| Current Frame | Int | Frame represented by the current geometry |
| Frame Rate | Float | Native archive frame rate |
| Frame Count | Int | Total archive frame count |
| Duration | Float | Archive duration in seconds |
| Frame Available | Bool | Whether the requested frame produced valid geometry |
| Source Size | Vector 2 | Encoded source width and height |

`Frame Rate` is read-only source metadata. `Playback Rate` is the independent
user control for playback speed.

### Frame and body behavior

- Resolve frames using `floor(time * nativeFrameRate)`.
- Loop with a positive modulo when Loop is enabled.
- Clamp to the first or last frame when Loop is disabled.
- Sort valid people by descending confidence, preserving stored order for ties.
- Apply Confidence before Maximum Bodies.
- Merge selected meshes by concatenating vertices and offsetting the fixed
  triangle indices for each body.
- Cache combined index data for body counts 1 through 8.
- Do not claim stable person identity across frames; the source archive does not
  contain tracked body identifiers.
- For a failed frame or a frame with no selected people, publish an empty
  geometry, zero Output Bodies, and `Frame Available = false`.

### Geometry and normals

- Keep one `BodyMeshGeometry` instance for the node lifetime.
- Mark its dynamic data for update only when the resolved frame or body-selection
  inputs change.
- Reuse allocated arrays and fixed topology wherever practical.
- Convert CoMotion camera coordinates into Fabric's coordinate convention in one
  documented location and apply the same conversion to positions and normals.
- Build smooth canonical normals once from the template and topology.
- Skin and normalize those normals with each body's blended joint transforms.
- Do not copy the example application's flat derivative-normal shader into the
  plugin.

### Execution and caching

- Load and validate the selected archive only when the folder changes or
  execution starts.
- Parse mesh constants once and share the resulting immutable data safely.
- Reconstruct only when the resolved frame, Confidence, or Maximum Bodies changes.
- Re-emitting an unchanged frame must perform no reconstruction or buffer rebuild.
- Begin with exact synchronous frame reconstruction so interactive and exported
  renders produce the requested frame deterministically.
- Profile reconstruction before introducing asynchronous presentation. If a
  background worker becomes necessary, specify how exact export waits for the
  requested frame before changing behavior.

## Phase 1 Milestones

### Milestone 0 — Plugin foundation

- [x] Create the Fabric plugin bundle target.
- [x] Add the principal `FabricPlugin` class.
- [x] Build against the adjacent Fabric checkout.
- [x] Install and ad-hoc sign the development bundle.
- [x] Verify plugin discovery with a temporary test node.

### Milestone 1 — Repository and core foundation

- [x] Add `BodyMeshProviderCore` as a local Swift package.
- [x] Add the core package to the plugin project.
- [x] Add a test target with no Fabric dependency.
- [x] Ignore local SampleData and include the reviewed mesh constants.
- [x] Verify the included constants byte count and SHA-256 during builds.
- [x] Make a missing constants resource fail with a focused setup message.

Acceptance: the core package builds and its empty test suite runs with Swift 5.9.

### Milestone 2 — Asset and archive reader

- [x] Decode optional `asset.json` metadata.
- [x] Memory-map and validate `frames.bin`.
- [x] Parse and validate the archive header and offset index.
- [x] Decode one requested frame without retaining all decoded frames.
- [x] Represent available and failed frames explicitly.
- [x] Test unsupported versions, invalid offsets, truncation, counts, and
      non-finite values.

Acceptance: every SampleData archive opens, reports matching metadata, and can
random-access its first, middle, and last frames.

### Milestone 3 — Mesh reconstruction

- [x] Parse and validate `CoMotionMeshConstants.bin`.
- [x] Reconstruct local and translated positions for one body.
- [x] Validate the fixed topology and all produced values.
- [x] Prepare canonical smooth normals once.
- [x] Skin and normalize smooth normals per frame.
- [ ] Add golden reconstruction tests with floating-point tolerances.

Acceptance: a known sample frame produces 6,890 finite vertices, 13,776 valid
triangles, and finite unit-length smooth normals matching the reference output.

### Milestone 4 — Dynamic Satin geometry

- [x] Implement `BodyMeshGeometry` with dynamic vertex data.
- [x] Preserve geometry identity across frame changes.
- [x] Merge one through eight bodies with correctly offset indices.
- [x] Reuse cached topology and avoid steady-state allocations.
- [ ] Verify front-face winding and coordinate conversion in Fabric.

Acceptance: a static sample body renders correctly through Fabric's existing
Mesh and Material nodes under ordinary scene lighting.

### Milestone 5 — Body Mesh Provider node

- [x] Replace the temporary test node with `BodyMeshProviderNode`.
- [x] Register all Phase 1 ports in stable order.
- [x] Add Codable settings and a procedural initializer.
- [x] Add the folder-selection settings view.
- [x] Implement graph-time and connected-Time behavior.
- [x] Implement loop, playback-rate, confidence, and body-count behavior.
- [x] Publish metadata and frame-status outputs only when they change.
- [x] Ensure teardown releases archive mappings and geometry resources.

Acceptance: selecting a SampleData folder and connecting Geometry to Fabric's
Mesh node provides controllable, time-varying body geometry.

### Milestone 6 — Verification and documentation

- [x] Run the complete core test suite.
- [x] Build the plugin in Debug and Release.
- [x] Verify Debug code signing and bundle metadata.
- [ ] Exercise every SampleData asset in Fabric.
- [ ] Verify graph save, reopen, and missing-folder behavior.
- [ ] Verify Movie Provider current-time synchronization.
- [ ] Profile unchanged-frame and changing-frame execution.
- [ ] Document setup, installation, example graph, and known limitations.

Acceptance: another checkout can build the plugin, select a prepared folder,
save the graph, reopen it, and reproduce playback without
CMResearchKit installed.

## Phase 1 Definition of Done

Phase 1 is complete when the plugin can load every current SampleData archive,
reconstruct and render the selected bodies through native Fabric nodes, expose
the agreed playback and metadata ports, synchronize to an external Time input,
survive document save/reopen, and perform zero reconstruction when the resolved
frame and body-selection inputs are unchanged.

## Phase 2 — Body Mesh Intrinsic Camera

Add a second plugin node named `Body Mesh Intrinsic Camera` after Phase 1
geometry behavior is verified.

Planned work:

- [x] Subclass Fabric's camera object-node family and provide a Satin perspective
  camera discovered through Fabric's existing camera selection mechanism.
- [x] Confirm that the current generator camera requires Source Size only; add
  provider outputs if a future archive format carries more calibration metadata.
- [x] Accept Source Size from Body Mesh Provider.
- [x] Match the example renderer's source-camera projection and aspect-fit math.
- [x] Keep the camera optional: without it, users continue to use ordinary Fabric
  Perspective or Orthographic Camera nodes.
- [ ] Compare reference frames from the CMResearchKit example application and
  Fabric at multiple output aspect ratios.

Phase 2 is complete when the same frame, source dimensions, and viewport produce
matching body framing in the example application and Fabric without the Body
Mesh Provider node directly mutating renderer or graph camera state.

## Explicitly Out of Scope for Phase 1

- Body Mesh Intrinsic Camera emulation.
- Live camera or video inference.
- Importing CMResearchKit.
- GPU-based SMPL reconstruction.
- Per-person materials or stable body tracking.
- A Geometry-array output.
- Rendering thumbnails or automatically locating source videos.
- Changes to Fabric core unless implementation proves a missing public plugin API.

## Implementation Rules

- Follow Fabric's repository engineering specification and Swift 5.9 baseline.
- Do not add third-party frameworks.
- Keep one node class per file.
- Keep Fabric and SwiftUI imports out of the core package.
- Use ParameterPorts for adjustable node inputs.
- Seed parameter-backed ports correctly and subscribe once.
- Keep source selection and runtime loading errors explicit.
- Do not perform file I/O, constants parsing, or full-archive decoding every frame.
- Update this plan when an accepted architectural boundary changes.
