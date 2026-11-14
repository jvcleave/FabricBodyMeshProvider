#include <metal_stdlib>
using namespace metal;

struct CharacterBindVertex
{
    float4 position;
    float4 normal;
};

struct CharacterInfluence
{
    uint joint;
    float weight;
};

struct CharacterSkinningJoint
{
    float4x4 positionMatrix;
    float4x4 normalMatrix;
};

kernel void skinCharacterSurface(
    const device CharacterBindVertex *bindVertices [[buffer(0)]],
    const device CharacterInfluence *influences [[buffer(1)]],
    const device CharacterSkinningJoint *joints [[buffer(2)]],
    device float4 *positions [[buffer(3)]],
    device float4 *normals [[buffer(4)]],
    constant uint2 &layout [[buffer(5)]],
    uint vertexIndex [[thread_position_in_grid]])
{
    if (vertexIndex >= layout.x) return;

    CharacterBindVertex bindVertex = bindVertices[vertexIndex];
    float4 position = 0.0f;
    float3 normal = 0.0f;
    uint start = vertexIndex * layout.y;
    for (uint lane = 0; lane < layout.y; ++lane)
    {
        CharacterInfluence influence = influences[start + lane];
        if (influence.weight == 0.0f) continue;
        const device CharacterSkinningJoint &joint = joints[influence.joint];
        position += (joint.positionMatrix * bindVertex.position) * influence.weight;
        normal += (joint.normalMatrix * bindVertex.normal).xyz * influence.weight;
    }

    float squaredLength = dot(normal, normal);
    if (squaredLength > FLT_MIN) normal *= rsqrt(squaredLength);
    else normal = bindVertex.normal.xyz;

    positions[vertexIndex] = float4(position.xyz, 1.0f);
    normals[vertexIndex] = float4(normal, 0.0f);
}
