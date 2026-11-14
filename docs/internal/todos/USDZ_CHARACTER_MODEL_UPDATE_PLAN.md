# Body Mesh Provider 2.0 USDZ update plan

In MessCharacterCreator, export **USDZ → NO MOTION** in the Human editor or
**USDZ → STATIC** in an Export Session. In Fabric, select the exported `.usdz`
as the **Character Model** and choose a **Motion Archive** separately. The same
Human can follow another capture, and a model swap is evaluated at the graph's
requested archive frame. The model uses Creator's fitted rig, skin, clothing,
hair, and optional embedded anatomy. [Creator export workflow](https://github.com/jvcleave/MessCharacterCreator/blob/3299888b1dc71abf8ac8cd5f402cb03e9c49acdc/README.md#human-editor-exports)

## Release and node design

Ship a breaking **Body Mesh Provider 2.0** in the existing plug-in repository.
Reuse its archive reader, frame selection, built-in body, and Intrinsic Camera.
Give the 2.0 renderable a new node identity and a sample graph. It attaches its
Satin meshes and their materials directly to Fabric's scene through
`BaseObjectNode.getObject()`, using the same scene integration as Model Mesh.
To move a version 1 graph to 2.0, replace the provider and its downstream Mesh
with the new renderable and reconnect the clock and camera if used. A separate
plug-in would make sense if both generations need to be installed in the same
Editor. [Current plug-in node](../../../BodyMeshProvider/BodyMeshProvider/Nodes/BodyMeshProviderNode.swift)
[Fabric scene integration](https://github.com/Fabric-Project/Fabric/blob/c1da66398ae4b28c266e0b3d4ef456d60c97f171/Fabric/Graph/Graph.swift#L1464-L1489)

Start with Fabric `c1da6639` and Satin `ff825e49`, the workspace baseline. The
plug-in owns the model import, per-surface materials, and compute skinning. For
direct playback of an exported baked clip, load the USDZ into Fabric's existing
**Model Mesh** node and drive **Time**. This update supersedes the plug-in's
earlier TCHR v2 proposal and uses Creator's existing USDZ export directly.
[Model Mesh](https://github.com/Fabric-Project/Fabric/blob/c1da66398ae4b28c266e0b3d4ef456d60c97f171/Fabric/Nodes/Object/Renderables/ModelMeshNode.swift#L29-L39) [Earlier export proposal](https://github.com/jvcleave/MessCharacterCreator/blob/3299888b1dc71abf8ac8cd5f402cb03e9c49acdc/docs/internal/todos/EXPORT_FOR_FABRIC_SPEC.md)

## Input and playback contract

- Accept Creator USDZs with `coMotionJointMap` v1 on `/Human/Rig`. Require a
  visible body bound to one mapped skeleton in Y-up meters at the model origin,
  one source index per joint in authored order, values from `-1` through `23`,
  and exactly one pelvis mapped to `0`. Unmapped joints follow their parents.
  Static and baked exports with the map can both supply a character. The selected
  archive supplies every pose and the root travel, even when the USDZ contains a
  clip. Older exports that lack the map require a fresh export from Creator.
  [MessScene USDZ contract](https://github.com/jvcleave/MessSceneApp/blob/5e236e3510dcb3aff493e0d2e3a784439100e464/Packages/MessSceneKit/Sources/MessSceneCore/Models/SceneBodyMeshUSDZ.swift#L16-L42)
- Resolve CoMotion v2 `frames.bin` inside the selected Creator `.messcapture`
  package or generator asset folder. Retain graph time or a connected **Time**,
  **Loop**, **Playback Rate**, **Confidence**, and **Maximum Bodies**. Give
  each selected detection its own pose and placement, and expose **Source Size**
  for Intrinsic Camera. A frame with zero selected detections draws zero
  characters.
- Keep **Built-in** as a model choice. Persist the model choice and archive
  as independent settings. Use a relative archive reference in the shipped
  sample. Resolve it from the document directory and serialize the resulting
  file URL when making Fabric's movie export clone. Picked files use absolute
  file URLs. Validate those references on reopen and export. Re-selecting a source retries that
  source. A missing, invalid, or unsupported selection clears the rendered
  character and uses Fabric's recoverable error path. A swap at a fixed **Time**
  reposes at that time on the next graph evaluation. A paused Editor applies
  the setting when evaluation resumes.
  [Fabric movie export graph copy](https://github.com/Fabric-Project/Fabric/blob/c1da66398ae4b28c266e0b3d4ef456d60c97f171/Fabric%20Editor/Export/GraphMovieExporter.swift#L271-L278)

## Implementation milestones

### 1. Prove import and rendering in the plug-in bundle

Pin `MessUSDZImportKit` at the mapped-rig API (`dfd0042`) and call
`USDZImporter.importFile` with `includeMappedSkeletons: true`. Use its bind
positions, normals, inverse binds, and complete weight arrays. The package
requires arm64, macOS 15.6 or later, and a Swift 6.2 toolchain. Verify package
resolution from a clean authenticated checkout and confirm discovery in the
source-built Editor. Verify both OpenUSD/TBB frameworks, their load paths,
schema resources, and signing in the installed and workspace-embedded bundle.
Confirm dependency access for anyone building 2.0 from source.
[USDZ importer manifest](https://github.com/jvcleave/MessUSDZImportKIt/blob/dfd0042a5b9af398afa87526a0ddd251ea410811/Package.swift)

Use the [supplied Creator export](#local-test-model) to prove that Fabric's
graph command buffer can skin and draw two material surfaces with a GPU-written
vertex buffer, including one surface with a cutout. Satin's vertex skinning
supports four influences per vertex. Use plug-in Metal compute to blend the full
influence lists and pass posed positions and normals to Satin meshes with vertex
skinning disabled. Confirm buffer layout, command ordering, and the cutout in the
Editor. Use Satin's PBR shader chunks and a plug-in shadow pipeline so the
visible surface and shadow map use the same texture binding and authored alpha
threshold. Prove source preparation on the first frame of a cold movie export
using the same model.
[Fabric graph render order](https://github.com/Fabric-Project/Fabric/blob/c1da66398ae4b28c266e0b3d4ef456d60c97f171/Fabric/Graph/GraphRenderer.swift#L342-L375) [Satin skinning shader](https://github.com/Fabric-Project/Satin/blob/ff825e4945ca19277355eda69831b9b19aad1533/Sources/Satin/Pipelines/Satin/Skinning.metal#L19-L28)

### 2. Retarget the selected archive frame

Keep typed Creator rig validation and the calibrated retargeter in
`BodyMeshProviderCore`. Port the existing retargeter from MessScene in Fabric's
Y-up coordinates and verify equivalent palettes and placement. The plug-in
adapts the USDZ importer's bind data and owns settings and GPU presentation.
[Retargeting reference](https://github.com/jvcleave/MessCharacterKit/blob/f5ebbad676175845c844d36d3852cf8221af77f8/Sources/MessCharacterKit/PreparedCharacterAsset.swift#L153) [MessScene rig and surface adapter](https://github.com/jvcleave/MessSceneApp/blob/5e236e3510dcb3aff493e0d2e3a784439100e464/Packages/MessSceneKit/Sources/MessSceneCore/Models/SceneBodyMeshUSDZ.swift)

Use the archive's 24 joint transforms to compute one palette per selected
body. Preserve the Human's authored proportions and the retargeter's pelvis
registration. Convert the skinned result to Fabric's Y-up model space and apply
the separate archive translation `(x, -y, -z)` once. Route non-rigid archive
transforms through Fabric's recoverable frame error for imported rigs. Preserve
authored draw triangles, UV orientation, albedo, color factors, double-sided
rendering, and the exported alpha threshold. Draw all surfaces of a body from
the same pose.
[MessScene palette and placement](https://github.com/jvcleave/MessSceneApp/blob/5e236e3510dcb3aff493e0d2e3a784439100e464/Packages/MessSceneKit/Sources/MessSceneMetal/CoMotion/SceneCoMotionFrameReconstructor.swift#L212-L246) [Full-weight compute reference](https://github.com/jvcleave/MessSceneApp/blob/5e236e3510dcb3aff493e0d2e3a784439100e464/Packages/MessSceneKit/Sources/MessSceneMetal/Resources/Shaders/SceneCoMotionSkinning.metal#L62-L92)

### 3. Connect selection and ship a sample graph

Use the plug-in settings for selection and an import worker for file access and
decoding. Cache the validated model by selection, and key poses by model, archive,
requested frame, and body filters. Reuse the open archive on a model swap.
Publish only the current model request, reuse static mesh data across draws, and
keep in-flight GPU buffers alive through completion. Fabric starts the cloned
export graph synchronously and renders the first frame immediately afterward.
Carry the preparation path proven in the bundle spike into the new node. Use
the sample to show both selectors and the Intrinsic Camera connection. Start
it with Built-in and the published `24sectest` archive beside the graph.
[Fabric export startup](https://github.com/Fabric-Project/Fabric/blob/c1da66398ae4b28c266e0b3d4ef456d60c97f171/Fabric/Graph/GraphExportRenderer.swift#L64-L110) [Plug-in sample workflow](../../../README.md#use-in-fabric)

## Acceptance

1. Re-export the same dressed Human from Creator in static and baked variants.
   Pair them with a short CoMotion v2 fixture that has joint rotation and
   nonzero root travel. Record the source frame indices, coordinate basis, and
   CPU reference positions and normals. Check one vertex whose fifth or sixth
   weight changes the pose. Compare both USDZ variants at the same requested
   frame against the reference using the archive as the animation source for
   both files. Re-export Human 02 and use its original capture for the local
   integration run. [MessScene's USDZ parity check](https://github.com/jvcleave/MessSceneApp/blob/5e236e3510dcb3aff493e0d2e3a784439100e464/Packages/MessSceneKit/Tests/MessSceneMetalTests/SceneBodyMeshUSDZTests.swift#L14)
   [Human 02 capture reference](https://github.com/jvcleave/MessSceneApp/blob/5e236e3510dcb3aff493e0d2e3a784439100e464/docs/internal/todos/GLB_COMOTION_PLAN.md#2-acceptance-with-creator-exports)
2. Render a dressed Human in Fabric with body masking, an albedo texture, and
   hair or clothing cutouts. Verify two detections pose independently, matched
   camera framing, and zero output for an empty frame. Swap models at fixed
   **Time**, change the archive, and recover from an unmapped or missing model
   by re-selecting it. Test the built-in choice through the same sample graph.
3. Save and reopen the 2.0 scene, then export a short movie from the reopened
   graph. Confirm the selected sources resolve and the movie's first and moved
   frames match the same preview frames. Run focused core checks and the macOS
   plug-in build, then exercise registration and playback in **Fabric Editor
   with Plug-ins** before recording a tested revision.

### Local test model

The supplied static export contains a v1 map for 53 joints, including one
pelvis, two skinned surfaces, one embedded image, and an alpha threshold of
0.5. Its body has 523 vertices with five or six nonzero influences. Use it for
import, material, and full-weight skinning checks. Pair it with a separate
CoMotion capture to exercise posing.

```text
~/Documents/MessCharacterCreator/EXPORTS/A5D810A8-A068-4134-9EBF-5696788DFE30/usdz/EFDFBADC-6A00-4828-8D6A-38296861E64E/model.usdz
```

The supplied copy for local verification is at
`~/Downloads/EFDFBADC-6A00-4828-8D6A-38296861E64E/model.usdz`. See the
[milestone handoff](../handoffs/usdz-character-model.md) for verification.
