import Foundation
import simd
import XCTest
@testable import BodyMeshProviderCore

final class CoMotionMeshReconstructorTests: XCTestCase
{
    func testRejectsInvalidConstantsSize()
    {
        XCTAssertThrowsError(try CoMotionMeshReconstructor(constantsData: Data()))
        { error in
            XCTAssertEqual(
                error as? CoMotionMeshReconstructionError,
                .invalidConstantsByteCount(
                    expected: CoMotionMeshReconstructor.expectedConstantsByteCount,
                    actual: 0
                )
            )
        }
    }

    func testRejectsInvalidConstantsHeader()
    {
        let constantsData = Data(
            repeating: 0,
            count: CoMotionMeshReconstructor.expectedConstantsByteCount
        )

        XCTAssertThrowsError(
            try CoMotionMeshReconstructor(constantsData: constantsData)
        )
        { error in
            XCTAssertEqual(
                error as? CoMotionMeshReconstructionError,
                .invalidConstantsHeader
            )
        }
    }

    func testRejectsNonFiniteConstants()
    {
        var constantsData = makeConstantsDataWithValidHeader()
        replaceUInt32(Float.nan.bitPattern, at: 16, in: &constantsData)

        XCTAssertThrowsError(
            try CoMotionMeshReconstructor(constantsData: constantsData)
        )
        { error in
            XCTAssertEqual(
                error as? CoMotionMeshReconstructionError,
                .nonFiniteConstants
            )
        }
    }

    func testRejectsOutOfRangeTriangleIndex()
    {
        var constantsData = makeConstantsDataWithValidHeader()
        let triangleDataOffset = CoMotionMeshReconstructor.expectedConstantsByteCount
            - CoMotionMeshReconstructor.triangleCount * 3 * MemoryLayout<UInt32>.size
        replaceUInt32(
            UInt32(CoMotionMeshReconstructor.vertexCount),
            at: triangleDataOffset,
            in: &constantsData
        )

        XCTAssertThrowsError(
            try CoMotionMeshReconstructor(constantsData: constantsData)
        )
        { error in
            XCTAssertEqual(
                error as? CoMotionMeshReconstructionError,
                .invalidTriangleIndex
            )
        }
    }

    func testRejectsInvalidSkinningWeights()
    {
        let constantsData = makeConstantsDataWithValidHeader()

        XCTAssertThrowsError(
            try CoMotionMeshReconstructor(constantsData: constantsData)
        )
        { error in
            XCTAssertEqual(
                error as? CoMotionMeshReconstructionError,
                .invalidSkinningWeights
            )
        }
    }

    func testReconstructsIncludedSample() throws
    {
        let constantsURL = repositoryURL
            .appending(path: "LocalAssets")
            .appending(path: "CoMotionMeshConstants.bin")
        let constantsData = try Data(
            contentsOf: constantsURL,
            options: .mappedIfSafe
        )
        let reconstructor = try CoMotionMeshReconstructor(constantsData: constantsData)
        let sampleDirectoryURL = repositoryURL
            .appending(path: "FabricScenes")
            .appending(path: "947B44F8-C4C3-4666-93B5-73BD71CE231A")
        let archiveReader = try CoMotionArchiveReader(directoryURL: sampleDirectoryURL)
        var firstPerson: CoMotionFramePerson?
        for frameIndex in 0 ..< archiveReader.frameCount
        {
            let frame = try archiveReader.frameAtIndex(frameIndex)
            if case let .available(people) = frame.status,
               let detectedPerson = people.first
            {
                firstPerson = detectedPerson
                break
            }
        }
        guard let firstPerson else
        {
            return XCTFail("Expected at least one detected person in the sample")
        }

        let mesh = try reconstructor.reconstructMesh(
            parameters: firstPerson.meshParameters
        )
        XCTAssertEqual(mesh.vertices.count, CoMotionMeshReconstructor.vertexCount)
        XCTAssertEqual(mesh.localVertices.count, CoMotionMeshReconstructor.vertexCount)
        XCTAssertEqual(mesh.normals.count, CoMotionMeshReconstructor.vertexCount)
        XCTAssertEqual(
            mesh.triangleIndices.count,
            CoMotionMeshReconstructor.triangleCount * 3
        )
        XCTAssertTrue(mesh.vertices.allSatisfy
        { vertex in
            vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite
        })
        XCTAssertTrue(mesh.normals.allSatisfy
        { normal in
            abs(simd_length(normal) - 1) < 0.0001
        })

        var workspace = CoMotionMeshReconstructionWorkspace()
        let renderableMesh = try reconstructor.reconstructMesh(
            parameters: firstPerson.meshParameters,
            workspace: &workspace,
            includeLocalVertices: false
        )
        XCTAssertTrue(renderableMesh.localVertices.isEmpty)
        XCTAssertEqual(renderableMesh.vertices, mesh.vertices)
        XCTAssertEqual(renderableMesh.normals, mesh.normals)

        let repeatedRenderableMesh = try reconstructor.reconstructMesh(
            parameters: firstPerson.meshParameters,
            workspace: &workspace,
            includeLocalVertices: false
        )
        XCTAssertEqual(repeatedRenderableMesh.vertices, renderableMesh.vertices)
        XCTAssertEqual(repeatedRenderableMesh.normals, renderableMesh.normals)

        let zeroSkinningParameters = try CoMotionMeshParameters(
            betas: firstPerson.meshParameters.betas,
            poseFeature: firstPerson.meshParameters.poseFeature,
            skinningTransforms: [Float](
                repeating: 0,
                count: CoMotionMeshParameters.skinningTransformCount
            ),
            translation: firstPerson.meshParameters.translation
        )
        XCTAssertThrowsError(
            try reconstructor.reconstructMesh(parameters: zeroSkinningParameters)
        )
        { error in
            XCTAssertEqual(
                error as? CoMotionMeshReconstructionError,
                .zeroHomogeneousWeight
            )
        }
    }

    private func makeConstantsDataWithValidHeader() -> Data
    {
        var constantsData = Data(
            repeating: 0,
            count: CoMotionMeshReconstructor.expectedConstantsByteCount
        )
        replaceUInt32(0x434D5348, at: 0, in: &constantsData)
        replaceUInt32(1, at: 4, in: &constantsData)
        replaceUInt32(
            UInt32(CoMotionMeshReconstructor.vertexCount),
            at: 8,
            in: &constantsData
        )
        replaceUInt32(
            UInt32(CoMotionMeshReconstructor.triangleCount),
            at: 12,
            in: &constantsData
        )
        return constantsData
    }

    private var repositoryURL: URL
    {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func replaceUInt32(
        _ value: UInt32,
        at offset: Int,
        in data: inout Data
    )
    {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue)
        { bytes in
            data.replaceSubrange(offset ..< offset + 4, with: bytes)
        }
    }
}
