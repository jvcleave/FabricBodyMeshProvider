# Internal Documentation

Start with the [README](../../README.md) for setup, sample scenes, and port
reference. Follow [AGENTS.md](../../AGENTS.md) for engineering guidance.

## Implementation

- The [plug-in plan](todos/PLUG_IN_PLAN.md) covers the CoMotion archive contract,
  the core package and Fabric node boundaries, and Satin's four-influence limit.
- The [USDZ update plan](todos/USDZ_CHARACTER_MODEL_UPDATE_PLAN.md) defines
  Creator model selection, live CoMotion retargeting, and the 2.0 renderable.

## Verification

Use the [core test command](../../README.md#tests) and the
[sample scenes](../../README.md#use-in-fabric) for a Fabric playback check.
See [SampleData](../../SampleData/README.md) for local test archives.

## Handoffs

Keep substantial Body Mesh Provider checkpoints in
`docs/internal/handoffs/<task-slug>.md`. Record the affected revisions, the
latest verification result, and the next exact action.
