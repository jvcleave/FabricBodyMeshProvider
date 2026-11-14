# USDZ character model support

## Scope

Body Mesh Provider 2.0 adds Body Mesh Character. It uses CoMotion v2 motion
archives with the built-in body or a mapped MessCharacterCreator export. The
Intrinsic Camera follows the archive's source dimensions. Start with the
[character sample](../../../FabricScenes/Character-sample.fabric) and
[update plan](../todos/USDZ_CHARACTER_MODEL_UPDATE_PLAN.md).

## Implementation

- Body Mesh Character keeps the USDZ model and motion archive selections
  independent. A model swap evaluates at the current requested archive frame.
- `BodyMeshProviderCore` validates the rig and retargets the pose. The plug-in
  reuses the built-in body reconstruction and skins imported meshes in Metal
  using every authored joint weight.
- Imported textures use Satin lighting and apply the same authored alpha test
  to color and shadow depth. The plug-in uses Satin's custom shadow pipeline.
- The sample starts with Built-in and the bundled `24sectest` archive. It
  connects Source Size to Intrinsic Camera and resolves its archive from the
  document directory before serializing a cold export graph.
- The importer is pinned to `dfd0042`. The plug-in targets Apple silicon with
  macOS 15.6 or later and requires a Swift 6.2 toolchain. Source builds need
  authenticated read access to MessUSDZImportKit.
- Creator USDZ exports must include the version 1 CoMotion joint map on
  `/Human/Rig`. The map records one source index per authored joint. This is
  the same requirement for static and baked exports.

## Verification

- Built and checked the signed Debug and Release plug-ins, native frameworks,
  schema resources, and bundled CoMotion mesh constants. The Debug workspace
  and the existing signed Editor loaded the plug-in.
- The core test run passed with one skip for optional local sample data.
- The release sample drew zero, one, and two selected bodies on the bundled
  archive. At fixed Time, switching between Built-in and an imported model
  restored the original pose on return. The reopened sample exported a
  short movie whose first and later silhouettes matched preview.
- Static and baked dressed USDZs rendered identically at the tested archive
  frames. The rig used all joint weights. GPU positions matched the MessScene
  CPU reference within 1.2 micrometers. A missing or unmapped model reported
  a recoverable error and a valid reselection restored playback.
- A supplied Human 02 static export and a fresh baked version rendered the
  same pixels on the first, middle, and last tested frames of its capture.
  The lit model responded to the directional light. An isolated surface's
  authored cutoff removed fragments from both color and the shadow map.
  Forward and Forward+ passed. The Editor reopened the graph and cold
  ProRes export preserved the preview silhouette and motion.

## Remaining issue

A supplemental Satin deferred-mode check of the Human 02 graph produced
black output with both the textured character material and Satin's stock
Standard material.
