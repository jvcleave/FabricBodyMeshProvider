# Handoff for Character Inspector

- Updated 2026-11-15, America/New_York
- Owning repository Body Mesh Provider
- Started on `main` at `3bd23c9`
- Fabric `546995f2` and Satin `ff825e49`

## Objective

Implement the optional inspector described in the
[update plan](../todos/CHARACTER_INSPECTOR_UPDATE_PLAN.md). It gives individual
mapped USDZ meshes and materials graph-driven controls.

## Current milestone

Verify a working inspector branch in the existing Character Switching sample
with live visibility and material inputs and working direct connections.

## Repository state

The update plan is indexed and the README documents the connections. The
plug-in registers Character Inspector and connects it through an action in
the character asset's Settings. The inspector and view share an active
immutable USDZ import. The Debug workspace Editor includes the plug-in.

## Decisions and constraints

- Keep the plug-in's import and runtime code in Body Mesh Provider. Use
  Fabric's existing ports for the character reference and overrides.
- Change dynamic ports through explicit inspector settings. Selecting a
  different USDZ keeps the configured ports and target paths.
- Use the imported material paths for selection and share the source import
  with the view. Keep mutable renderables in the view.

## Relevant files

- `BodyMeshProvider/BodyMeshProvider/Nodes/BodyMeshCharacterAssetNode.swift`
- `BodyMeshProvider/BodyMeshProvider/Nodes/BodyMeshSceneViewNode.swift`
- `BodyMeshProvider/BodyMeshProvider/Character/CharacterModelImport.swift`
- `BodyMeshProvider/BodyMeshProvider/Character/CharacterModelRenderable.swift`

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build-workspace.sh`
  built and signed the Debug workspace Editor.
- The core test suite ran 22 tests with zero failures and one skip for local
  sample data.
- A Metal runtime check loaded the installed plug-in and the original sample.
  It verified direct connections, visibility by mesh and by material, live
  material replacement and disconnect at a fixed pose, shared CoMotion,
  two slots with one prepared USDZ, missing targets, port and wire persistence,
  and a frame rendered from a cold export graph. The build-cache log is
  `.build/logs/character-inspector-check.log` in the workspace.
- Built and installed the Debug plug-in for Xcode's existing workspace Editor
  product and verified its signature hash was unchanged. In that Editor, the
  asset's **Add Character Inspector** action inserted the node in a scratch
  Character Switching graph. The inspector loaded `human2.usdz` targets and
  exposed the gun visibility and body material inlets from Settings.
- Added [Character Inspector.fabric](../../../FabricScenes/Character%20Inspector.fabric).
  Its direct and inspected branches render from the same USDZ and motion
  archive. Verified its Published controls in Xcode's Editor and rendered
  the original and relocated graph through the export renderer.

## Remaining issues

The implemented milestone passed the runtime and Editor checks. The workspace
pin identifies the tested plug-in revision.

## Next exact action

Review the plug-in diff and the update plan before recording a component
revision.
