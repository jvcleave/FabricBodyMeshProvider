# Shared CoMotion playback sample

- Updated 2026-11-15
- Owning repository `/Users/jvcleave/Documents/GitHub/JVC_FABRIC_PLUGINS/BodyMeshProvider`
- Branch `codex/body-mesh-usdz` at `45c84bb`

## Objective

Ship the [two-character example](../todos/USDZ_CHARACTER_MODEL_UPDATE_PLAN.md#shipped-example-scene-goal)
with one CoMotion archive, timed character switches, a movable view, and its
calibrated camera.

## Current milestone

The subgraph example was committed and pushed as `45c84bb`. The approved next
milestone is a root graph with two USDZ source nodes, one CoMotion Data node,
one standalone Body Mesh View, and a separate view camera. Verify both loaded
models at the switch boundaries, camera following, and lit live and exported
frames from a moved sample folder.

The standalone scene was pushed as `7acaaa5`. The follow-up added an optional
wireframe around the active character's posed bounds. The sample publishes
the toggle with a default of off.

## Completed milestones

CoMotion Data feeds the same selected archive frame to two Body Mesh Character
nodes, including through published inlets on a regular Fabric Sub Graph.
The source opens folder-based captures and standalone `.bin` archives.

Body Mesh View places both characters and their child Intrinsic Camera as an
ordinary Fabric Sub Graph. The portable Character Switching scene includes two
USDZs and one archive, with Frames per Character set to 30.

## Decisions and constraints

- Use Fabric's existing collection ports and the plug-in's archive reader.
- An unwired character uses its saved Motion Archive and playback controls.
- Use the existing signed Fabric Editor build for integration.
- Keep the legacy subgraph type available for saved graphs. For the standalone
  view, prepare both model references and select the active one by index. The
  camera consumes the view's camera transform and CoMotion Data's Source Size.
- The [loader investigation](https://github.com/jvcleave/JVC_FABRIC_PLUGINS/issues/1)
  tracks mapped USDZ import parity.

## Repository state

The flat sample and its assets are together in
[`FabricScenes/Character Switching`](../../../FabricScenes/Character%20Switching).

The USDZ update plan contains the approved sample goal and USDZ-only import
contract. The existing Character sample and 2.0 verification are recorded in
the [USDZ handoff](usdz-character-model.md).

CoMotion Data now publishes a frame and source dimensions. Body Mesh Character
uses the wired frame for its model and detection selection. Both settings paths
resolve relative asset references for cold graph copies.

The standalone view prepares both USDZs and poses the active model from its
CoMotion Frame inlet. Camera Distance shifts the capture eye relative to the
view pivot. Body Mesh View Camera receives that eye transform and Source Size
via ports. Body Mesh View Group retains the legacy subgraph implementation.

## Relevant files

- `BodyMeshProvider/BodyMeshProvider/Nodes/BodyMeshCharacterNode.swift` owns local playback and posing.
- `BodyMeshProvider/BodyMeshProvider/Playback/BodyMeshFrameSelection.swift` resolves time and selects detections.
- `BodyMeshProviderCore/Sources/BodyMeshProviderCore/Archive/CoMotionArchiveReader.swift` validates and samples archives.

## Verification

- Debug plug-in build passed in the existing
  `MESS-LocalBuilds/FabricBodyMeshProvider-USDZ/Xcode` cache.
  Build output is recorded in `shared-motion-debug.log`.
- The runtime check linked against the existing signed Editor's Fabric
  framework. Both supplied USDZs advanced through archive frames 1 to 5 from
  one `motiondata.bin` while visibility switched on render frames 2 and 4.
  The reopened graph and its cold export copy rendered identical frames.
- A folder source published to both characters. Clearing the shared source
  cleared both poses. The existing unwired Character sample passed.
- The signed Debug plug-in is installed in Fabric's user plug-in folder. The
  existing Editor discovers it on its next launch.
- The local proof graph and log are in the build cache at
  `FabricBodyMeshProvider-USDZ/runtime/shared-playback/Shared playback check.fabric`
  and `verify.log`.
- Body Mesh View Debug build passed in the same cache. Build output is recorded
  in `body-mesh-view-debug.log`.
- Translation, rotation, and uniform scale retained the child camera’s source
  framing. A parent scene camera also rendered the placed view.
- The initial ProRes check matched preview silhouettes at frames 0, 30, and 60.
  The original light shared its position with its target, which left the live
  character silhouettes black.
- Moving the sample's Directional Light to `[1.5, 2.1, 3]` made both models
  visible as they alternated in the existing Xcode-launched Fabric Editor.
- A relocated copy with relative references to the two models and archive
  produced nonzero RGB for both models across nine sampled frames using the
  Xcode build's Fabric framework. See
  `FabricBodyMeshProvider-USDZ/runtime/body-mesh-view/xcode-output-check/saved-lighting.log`.
- Saving the sample in the Editor expands its three relative plug-in settings
  URLs to absolute paths. The verified relocated copy keeps relative URLs.
- The standalone plug-in built in the existing Debug cache. See
  `FabricBodyMeshProvider-USDZ/standalone-view-debug.log`.
- The relocated graph prepared both models on frame 0 and switched on render
  frames 30 and 60 while CoMotion advanced through archive frames 1, 61, and
  121. The camera followed translation, rotation, and scale. The lit ProRes
  frames matched the preview silhouettes, and the legacy group scene still
  rendered. See `FabricBodyMeshProvider-USDZ/runtime/standalone-view/verify.log`.
- Both models rendered in the repository sample in the Xcode-launched Editor.
  Both USDZ reference nodes and the companion camera are visible at the root.
  The Editor executable and debug library hashes matched before and after
  the plug-in update.
- The bounding box ran on both models in the preview and in a ProRes export.
  Turning it off restored the original preview pixels. Clearing motion hid
  the box. See `FabricBodyMeshProvider-USDZ/runtime/bounding-box/verify.log`.
- The Xcode-launched Editor drew the outline with the toggle on in a
  verification copy and reopened the repository sample with the published
  toggle off.

## Next exact action

Record the pushed plug-in revision in the Fabric workspace.
