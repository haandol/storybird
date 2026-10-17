import Foundation
import XCTest
@testable import StorybirdCore

final class MaskEffectTests: XCTestCase {
    func test_modesAndSpaces_areIndependentRequiredChoicesAndLegacyEffectsStillDecode() throws {
        let project = fixture()
        for mode in LayerTimingMode.allCases {
            for space in MaskEffect.CoordinateSpace.allCases {
                let edited = try add(to: project, mode: mode, space: space)
                let mask = try value(edited)
                XCTAssertEqual(mask.timingMode, mode)
                XCTAssertEqual(mask.coordinateSpace, space)
                XCTAssertEqual(mask.sceneAnchor != nil, mode == .scene)
                XCTAssertEqual(mask.colorHex, "#000000")
                XCTAssertEqual(try JSONDecoder().decode(DemoProject.self, from: JSONEncoder().encode(edited)), edited)
                for key in ["timingMode", "coordinateSpace"] {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mask)) as? [String: Any])
                    object.removeValue(forKey: key)
                    XCTAssertThrowsError(try JSONDecoder().decode(MaskEffect.self, from: JSONSerialization.data(withJSONObject: object)))
                }
            }
        }
        XCTAssertEqual(try JSONDecoder().decode(DemoProject.self, from: JSONEncoder().encode(project)).effects, [])
    }

    func test_invalidRectangleTimeAndAnchor_rejectWholeMaskWithoutChangingOriginal() throws {
        let project = fixture()
        let before = project
        for (x, y, width, height) in [(0.0, 0.0, 0.0, 0.5), (0.8, 0, 0.3, 0.5), (-0.1, 0, 0.5, 0.5),
                                    (0, 0, 0.5, -0.1), (Double.nan, 0, 0.5, 0.5), (1, 0, 1e-100, 0.5)] {
            XCTAssertThrowsError(try MaskEditor.create(in: project, startTime: 1, endTime: 3, x: x, y: y, width: width, height: height,
                timingMode: .project, coordinateSpace: .canvas))
        }
        for (start, end) in [(-1.0, 1.0), (1, 1), (1, 9), (Double.nan, 2)] {
            XCTAssertThrowsError(try MaskEditor.create(in: project, startTime: start, endTime: end, x: 0.1, y: 0.1, width: 0.5, height: 0.5,
                timingMode: .project, coordinateSpace: .canvas))
        }
        XCTAssertThrowsError(try MaskEditor.create(in: project, startTime: 1, endTime: 3, x: 0, y: 0, width: 1, height: 1,
            timingMode: .project, coordinateSpace: .canvas, colorHex: "#00000080"))
        let withCard = try DemoEffectEditor.insertTitle(in: project, after: project.clips[0].id, duration: 1)
        XCTAssertThrowsError(try add(to: withCard, mode: .scene, start: 4.5, end: 5.5))
        XCTAssertNoThrow(try add(to: withCard, mode: .project, start: 4.5, end: 5.5))
        XCTAssertEqual(project, before)
    }

    func test_sceneMoveSplitTrimAndSpeed_keepDurationAndExactOwner() throws {
        var project = try add(to: fixture(), mode: .scene)
        project = try add(to: project, mode: .project, color: "#FF0000")
        let sceneID = project.effects[0].id, fixedID = project.effects[1].id
        let card = try DemoEffectEditor.insertTitle(in: project, after: nil, duration: 1)
        try VideoProjectValidator.validate(card)
        XCTAssertEqual(try value(card, id: sceneID).startTime, 2)
        XCTAssertEqual(try value(card, id: sceneID).endTime, 4)
        let withoutCard = try DemoEffectEditor.delete(card.effects.last!.id, from: card)
        XCTAssertEqual(try value(withoutCard, id: sceneID), try value(project, id: sceneID))
        let moved = try VideoTimelineEditor.move(project: project, clipID: project.clips[0].id, destination: 1)
        XCTAssertEqual(try value(moved, id: sceneID).startTime, 5)
        XCTAssertEqual(try value(moved, id: sceneID).endTime, 7)
        XCTAssertEqual(try value(moved, id: fixedID).startTime, 1)
        let split = try VideoTimelineEditor.split(project: project, clipID: project.clips[0].id, sourceTime: 1)
        XCTAssertEqual(try value(split, id: sceneID).sceneAnchor?.clipID, split.clips[1].id)
        XCTAssertEqual(split.effects.filter(\.isMask).count, 2)
        let trimmed = try VideoTimelineEditor.trim(project: project, clipID: project.clips[0].id, sourceStart: 1.5, sourceEnd: 4)
        XCTAssertFalse(trimmed.effects.contains { $0.id == sceneID })
        XCTAssertTrue(trimmed.effects.contains { $0.id == fixedID })
        let sped = try ProjectEditPlanner.plan([ProjectEdit(target: .clip, id: project.clips[0].id, action: .update,
            values: ["playback_rate": .number(2)])], in: project).project
        XCTAssertEqual(try value(sped, id: sceneID).startTime, 0.5)
        XCTAssertEqual(try value(sped, id: sceneID).endTime, 2.5)
        var single = project; single.clips.removeLast()
        XCTAssertThrowsError(try ProjectEditPlanner.plan([ProjectEdit(target: .clip, id: single.clips[0].id, action: .update,
            values: ["playback_rate": .number(4)])], in: single))
    }

    func test_clipDuplicate_copiesOnlySceneMasksWithNewIDsAndFixedDuration() throws {
        var project = try add(to: fixture(), mode: .scene)
        project = try add(to: project, mode: .project)
        let result = try VideoTimelineEditor.duplicate(project: project, clipID: project.clips[0].id, destination: 1)
        let masks = result.effects.compactMap { if case let .mask(value) = $0 { value } else { nil } }
        XCTAssertEqual(masks.count, 3)
        XCTAssertEqual(Set(masks.map(\.id)).count, 3)
        XCTAssertEqual(masks[2].sceneAnchor?.clipID, result.clips[1].id)
        XCTAssertEqual(masks[2].startTime, 5)
        XCTAssertEqual(masks[2].endTime, 7)
        XCTAssertEqual(masks[1].timingMode, .project)
    }

    func test_maskReorderAndBatchMove_preserveOtherEffectsAndExposeOnlyApplicableFields() throws {
        var project = fixture()
        let spotlight = DemoEffect.spotlight(SpotlightEffect(startTime: 0, endTime: 1, x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        project.effects = [spotlight]
        project = try add(to: project, mode: .project, color: "#FF0000")
        let red = project.effects.last!.id
        let zoom = DemoEffect.panZoom(PanZoomEffect(startTime: 0, endTime: 1, endX: 0.5, endY: 0.5, endScale: 2))
        project.effects.append(zoom)
        project = try add(to: project, mode: .scene, color: "#0000FF")
        let blue = project.effects.last!.id
        let plan = try ProjectEditPlanner.plan([ProjectEdit(target: .effect, id: red, action: .update,
            values: ["order_index": .number(1)])], in: project)
        XCTAssertEqual(plan.project.effects.map(\.id), [spotlight.id, blue, zoom.id, red])
        let values = try ProjectEditPlanner.values(for: ProjectEditReference(target: .effect, id: red), in: plan.project)
        XCTAssertEqual(values["order_index"], .number(1))
        XCTAssertEqual(ProjectEditFields.effect(.mask(try value(project, id: red)))["order_index"]?.type, .integer)
        for fields: [String: ProjectEditValue] in [["order_index": .number(0.5)], ["order_index": .number(2)], ["opacity": .number(0.5)], ["dim_opacity": .number(0.5)]] {
            XCTAssertThrowsError(try MaskEditor.update(red, in: project, values: fields))
        }
        let moved = try TimelineLayerEditor.move(.effect(blue), by: 3, in: project)
        XCTAssertEqual(try value(moved, id: blue).startTime, 4)
        XCTAssertEqual(try value(moved, id: blue).endTime, 6)
        XCTAssertEqual(try value(moved, id: blue).sceneAnchor?.clipID, project.clips[1].id)
    }

    func test_geometry_usesIndependentSpaceCameraAndConservativePixelCoverage() throws {
        var project = fixture()
        project.canvas.preset = .square
        project = try add(to: project, mode: .project, space: .content)
        let contentID = project.effects.last!.id
        project = try add(to: project, mode: .scene, space: .canvas)
        let canvasID = project.effects.last!.id
        let normal = try MaskGeometry.layers(in: project, at: 1)
        XCTAssertEqual(normal.first { $0.id == contentID }?.pixelRect, CGRect(x: 270, y: 388, width: 540, height: 304))
        XCTAssertEqual(normal.first { $0.id == canvasID }?.pixelRect, CGRect(x: 270, y: 270, width: 540, height: 540))
        project.effects.append(.panZoom(PanZoomEffect(startTime: 0, endTime: 4, startScale: 2, endX: 0.5, endY: 0.5, endScale: 2)))
        let zoomed = try MaskGeometry.layers(in: project, at: 1)
        XCTAssertEqual(zoomed.first { $0.id == contentID }?.pixelRect, CGRect(x: 0, y: 236, width: 1080, height: 608))
        XCTAssertEqual(zoomed.first { $0.id == canvasID }?.pixelRect, normal.first { $0.id == canvasID }?.pixelRect)
        let tiny = try MaskEditor.create(in: fixture(), startTime: 0, endTime: 1, x: 0.5, y: 0.5, width: 1e-100, height: 1e-100,
            timingMode: .project, coordinateSpace: .canvas)
        XCTAssertEqual(try MaskGeometry.layers(in: tiny, at: 0.5)[0].pixelRect, CGRect(x: 960, y: 540, width: 1, height: 1))
        var malformed = tiny
        if case var .mask(mask) = malformed.effects[0] { mask.colorHex = "invalid"; malformed.effects[0] = .mask(mask) }
        XCTAssertThrowsError(try MaskGeometry.layers(in: malformed, at: 4), "Even an inactive malformed mask must fail closed.")
    }

    private func fixture() -> DemoProject {
        var project = DemoProject(name: "Masks", recording: VideoRecordingAsset(filename: "source.mp4", duration: 8, width: 1920, height: 1080))
        project.clips = [VideoClip(sourceStart: 0, sourceEnd: 4), VideoClip(sourceStart: 4, sourceEnd: 8)]
        return project
    }
    private func add(to project: DemoProject, mode: LayerTimingMode, space: MaskEffect.CoordinateSpace = .canvas,
                     start: Double = 1, end: Double = 3, color: String = "#000000") throws -> DemoProject {
        try MaskEditor.create(in: project, startTime: start, endTime: end, x: 0.25, y: 0.25, width: 0.5, height: 0.5,
            timingMode: mode, coordinateSpace: space, colorHex: color)
    }
    private func value(_ project: DemoProject, id: UUID? = nil) throws -> MaskEffect {
        let effect = try XCTUnwrap(project.effects.first { id == nil ? $0.isMask : $0.id == id })
        guard case let .mask(value) = effect else { throw DemoEffectEditError.effectNotFound }
        return value
    }
}
