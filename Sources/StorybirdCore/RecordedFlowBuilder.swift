import CoreGraphics
import Foundation

public enum RecordedFlowBuilder {
    @discardableResult
    public static func append(
        nextStep: DemoStep,
        clickPoint: CGPoint,
        from sourceStepID: UUID,
        to project: inout DemoProject
    ) throws -> UUID {
        guard let sourceIndex = project.steps.firstIndex(where: {
            $0.id == sourceStepID
        }) else {
            throw RecordedFlowBuilderError.sourceStepNotFound
        }

        project.steps[sourceIndex].hotspots.append(
            Hotspot(
                x: clickPoint.x,
                y: clickPoint.y,
                title: "Continue",
                targetStepID: nextStep.id
            )
        )
        project.steps.append(nextStep)
        project.updatedAt = Date()
        return nextStep.id
    }
}

public enum RecordedFlowBuilderError: LocalizedError {
    case sourceStepNotFound

    public var errorDescription: String? {
        "The previous recorded screen no longer exists."
    }
}
