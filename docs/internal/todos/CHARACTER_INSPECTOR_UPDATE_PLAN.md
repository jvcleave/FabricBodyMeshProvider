# Character Inspector update plan

Add an optional **Character Inspector** between **Body Mesh Character Asset**
and **Body Mesh View**. It exposes live visibility and material controls for
selected USD targets. A direct connection renders the authored character.

```text
Body Mesh Character Asset ──► Character Inspector ──► Body Mesh View
                               Gun Visible   ◄── Boolean control
                               Body Material ◄── Physical Material
```

## Authoring and playback

- Add the inspector from the node library or use **Add Character Inspector**
  in a character asset's Settings. Each character branch can use its own
  inspector.
- List renderable meshes and their imported materials by name and USD path.
  Settings selects which targets expose ports and saves their bindings. Live
  visibility uses Boolean parameter inlets. Replacement materials use Fabric
  Material inlets. Both work through the procedural graph API.
- Mesh visibility applies to every surface on the selected mesh. Material
  visibility applies to every surface bound to the selected material. When
  both are present, both must allow the surface to draw. A material inlet
  replaces the bound material. Clearing its value restores the authored one.
- Keep saved target paths when the input character changes. A missing target
  stays available to remove in Settings and has no effect on that character.

## Implementation

1. Accept the existing USDZ path or a Fabric value carrying that path and the
   overrides on the view's **Character A/B** inputs. Keep their registry keys
   so saved scenes restore their wires.
2. Share one active USDZ import between inspection and view preparation. Cache
   by source independently of live overrides. Keep the pose and mutable Satin
   meshes owned by the view. Apply overrides on the selected character's
   existing meshes so both slots can reuse one USDZ with different choices.
3. Register **Character Inspector** and its Codable port layout. Read mesh and
   material choices from the import. Reconcile ports on settings edits and
   restore retained ports and values from the saved graph. Keep graph topology
   edits out of execution.
4. Use the existing character skinning and draw path. Hidden meshes contribute
   neither color, shadows, nor the optional posed bounds. Material replacement
   uses the connected material's shading and cutout behavior.

## Verification

- Open the existing Character Switching scene and verify direct playback on
  both character slots.
- Put an inspector on the `human2.usdz` branch. Hide a gun, replace the body
  material, and switch back while shared CoMotion playback advances.
- Exercise a fixed motion frame, two slots sharing one USDZ, missing targets,
  material disconnect, and graph save and reopen with connected inputs.
- Verify discovery in the workspace Editor and compare preview with a cold
  export of the inspected graph.
