import AppKit
import SceneKit
import simd

@_silgen_name("AxialTestInput") func testInput(_ value: Double)
@_silgen_name("AxialTestMapped") func testMapped(_ value: Double)
@_silgen_name("AxialTestReset") func testReset()

@main enum SceneTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let renderer = TestRenderer()
        var profile = Profile()
        renderer.configure(device: 1, profile: profile)
        let view = TestSceneView();view.scene = renderer.scene;view.motionSource = renderer;view.delegate = renderer
        precondition(!renderer.needsFrames)
        testInput(100);precondition(renderer.needsFrames)
        renderer.renderer(view, updateAtTime: 1)
        renderer.renderer(view, updateAtTime: 1.01)
        let moved = renderer.object.simdTransform
        precondition(moved != matrix_identity_float4x4)
        testInput(0);renderer.renderer(view, updateAtTime: 1.02)
        precondition(!renderer.needsFrames)
        renderer.renderer(view, updateAtTime: 20)
        precondition(renderer.object.simdTransform == moved)
        testInput(100);renderer.renderer(view, updateAtTime: 21)
        precondition(renderer.object.simdTransform == moved, "Resuming must not integrate time spent idle")
        profile.translation = false;profile.rotation = false
        renderer.configure(device: 1, profile: profile);precondition(!renderer.needsFrames)
        profile = Profile();profile.deadzone = Array(repeating: 150, count: 6)
        renderer.configure(device: 1, profile: profile);precondition(!renderer.needsFrames)
        profile = Profile();renderer.configure(device: 1, profile: profile)
        testInput(100);precondition(renderer.needsFrames)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(!renderer.needsFrames, "Stale input must stop rendering")
        renderer.reset();precondition(renderer.needsFrames)
        renderer.renderer(view, updateAtTime: 22)
        precondition(renderer.object.simdTransform == matrix_identity_float4x4)
        precondition(!renderer.needsFrames)
        renderer.configure(device: 2, profile: profile)
        testInput(100);precondition(!renderer.needsFrames, "Other devices must not wake the scene")
        view.updateRendering();precondition(!view.isPlaying && !view.rendersContinuously, "Detached views must stop")

        // Raw fallback honours per-axis enable as well as the translation/rotation toggles.
        profile = Profile();profile.enabled = Array(repeating: false, count: 6)
        renderer.configure(device: 1, profile: profile)
        testInput(100);precondition(!renderer.needsFrames, "Disabled axes must not move the raw fallback")

        // Mapped stream: the service's post-mapping output drives the car directly.
        profile = Profile();renderer.configure(device: 1, profile: profile)
        func drive(raw: Double, mapped: Double?, at start: TimeInterval) -> SIMD3<Float> {
            renderer.pauseTiming();renderer.reset()
            testInput(raw);if let mapped {testMapped(mapped)}
            renderer.renderer(view, updateAtTime: start)
            renderer.renderer(view, updateAtTime: start + 0.01)
            let column = renderer.object.simdTransform.columns.3
            testInput(0);if mapped != nil {testMapped(0)}
            renderer.renderer(view, updateAtTime: start + 0.02)
            precondition(!renderer.needsFrames)
            return SIMD3(column.x, column.y, column.z)
        }
        let rawMove = drive(raw: 100, mapped: nil, at: 30)
        precondition(simd_length(rawMove) > 0, "Raw fallback must move the car")
        let mappedMove = drive(raw: 100, mapped: -100, at: 40)
        precondition(simd_dot(rawMove, mappedMove) < 0 && abs(simd_length(rawMove) - simd_length(mappedMove)) < 1e-4,
                     "Mapped output must replace the raw axes")
        testInput(100);testMapped(0);precondition(!renderer.needsFrames, "A zero mapped frame must win over raw motion")
        profile.deadzone = Array(repeating: 150, count: 6);profile.enabled = Array(repeating: false, count: 6)
        renderer.configure(device: 1, profile: profile)
        testInput(100);testMapped(100);precondition(renderer.needsFrames, "Mapped frames are already shaped by the service")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(!renderer.needsFrames, "Stale mapped input must stop rendering")
        testInput(100);testMapped(100);precondition(renderer.needsFrames, "Fresh mapped input must wake the scene")
        renderer.configure(device: 2, profile: profile)
        testInput(100);testMapped(100);precondition(!renderer.needsFrames, "Other devices' mapped frames must not wake the scene")
        renderer.configure(device: 1, profile: profile)
        testReset()
        testInput(100);precondition(!renderer.needsFrames, "Without mapped frames the local filter applies again")
        profile = Profile();renderer.configure(device: 1, profile: profile)
        precondition(renderer.needsFrames, "Raw fallback resumes after a reset clears mapped state")
        print("PASS: movement, stop, resume, disabled axes, dead zone, stale input, reset, device selection and mapped stream")
    }
}
