import MetalKit
import SwiftUI

/// The 5620's 800x1024x1 screen as a Metal view: uploads the packed VRAM
/// (100x1024 R8Uint) when the FrameStore has a newer generation and lets
/// the fragment shader expand bits with the phosphor tint.
struct FramebufferView: PlatformViewRepresentable {
    let frames: FrameStore
    var phosphor: SIMD3<Float> = SIMD3(0.45, 1.0, 0.60)

    func makePlatformView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
        #if os(macOS)
        view.layer?.backgroundColor = NSColor.black.cgColor
        #else
        view.isOpaque = true
        view.backgroundColor = .black
        #endif
        view.delegate = context.coordinator
        context.coordinator.configure(for: view)
        return view
    }

    func updatePlatformView(_ view: MTKView, context: Context) {
        context.coordinator.phosphor = phosphor
    }

    func makeCoordinator() -> Renderer { Renderer(frames: frames, phosphor: phosphor) }

    final class Renderer: NSObject, MTKViewDelegate {
        private let frames: FrameStore
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var staging = [UInt8](repeating: 0, count: 102_400)
        private var seenGeneration: UInt64 = .max   // force first upload
        /// Colour of a lit pixel; the user picks it in Settings.
        var phosphor: SIMD3<Float>

        init(frames: FrameStore, phosphor: SIMD3<Float>) {
            self.frames = frames
            self.phosphor = phosphor
        }

        func configure(for view: MTKView) {
            guard let device = view.device else { return }
            queue = device.makeCommandQueue()

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Uint, width: 100, height: 1024, mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)

            guard let library = device.makeDefaultLibrary(),
                  let vfn = library.makeFunction(name: "fb_vertex"),
                  let ffn = library.makeFunction(name: "fb_fragment") else { return }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vfn
            pd.fragmentFunction = ffn
            pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: pd)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let queue, let pipeline, let texture,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor else { return }

            let gen = frames.copy(into: &staging, ifNewerThan: seenGeneration)
            if gen != seenGeneration {
                seenGeneration = gen
                texture.replace(region: MTLRegionMake2D(0, 0, 100, 1024),
                                mipmapLevel: 0, withBytes: staging, bytesPerRow: 100)
            }

            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            var tint = phosphor
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
