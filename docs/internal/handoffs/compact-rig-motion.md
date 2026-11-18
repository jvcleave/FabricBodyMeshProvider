# Compact Creator rig motion

Completed November 18, 2026. Body Mesh Character accepts a mapped USDZ and
Creator’s v3 frames.bin directly, from a .messcapture, or from an archive
directory. The reader validates the new schema, offsets, counts, confidence,
rotations and translations. It preserves v2 for both rigged Humans and
canonical mesh reconstruction. Selecting v3 with a built-in body reports
the model requirement.

## Verification

- The core suite executed 23 tests with zero failures and one skip for the
  optional local SampleData. The included v2 Fabric scene asset was exercised.
- The standalone Debug plug-in built and installed. The signed bundle passed
  strict verification and contains the reviewed 18,851,008-byte constants.
- The Debug Fabric workspace built and embedded the updated plug-in. The
  Fabric importer opened Creator’s neutral USDZ with 53 joints and a skinned
  body surface. The independent Fabric reader and retargeter reproduced all
  2,369 v2 detection palettes and camera translations from the two v3 exports.
- A Metal host using the rebuilt Editor’s framework and embedded plug-in
  reopened the Character sample graph with each of the four archive inputs.
  For Felix it rendered ordinals 0, 425 and 849. For Richard it rendered
  0, 563 and 1125. The v2 and v3 RGBA buffers were byte-identical for each
  pair. No source scene was edited for verification.

The workspace records the tested component revision. Reopen the rebuilt
Editor to pick up its embedded plug-in.
