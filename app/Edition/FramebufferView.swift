import MetalKit
import SwiftUI

/// The 5620's 1-bit screen as a Metal view: uploads the packed VRAM
/// (width/8 x height, R8Uint) when the FrameStore has a newer generation
/// and lets the fragment shader expand bits with the phosphor tint.
///
/// The screen is resizable while the terminal runs, so the texture is built
/// from whatever geometry arrives with a frame rather than at configure
/// time, and the same geometry is handed to the shader.
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
        private var device: MTLDevice?
        private var texture: MTLTexture?
        private var textureGeometry = FrameStore.Geometry(width: 0, height: 0)
        private var staging = [UInt8](repeating: 0, count: FrameStore.Geometry.stock.byteCount)
        private var seenGeneration: UInt64 = .max   // force first upload
        /// Colour of a lit pixel; the user picks it in Settings.
        var phosphor: SIMD3<Float>

        init(frames: FrameStore, phosphor: SIMD3<Float>) {
            self.frames = frames
            self.phosphor = phosphor
        }

        func configure(for view: MTKView) {
            guard let device = view.device else { return }
            self.device = device
            queue = device.makeCommandQueue()

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
            guard let queue, let pipeline, let device,
                  let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor else { return }

            let (gen, geometry) = frames.copy(into: &staging, ifNewerThan: seenGeneration)
            if gen != seenGeneration {
                seenGeneration = gen
                if geometry != textureGeometry {
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .r8Uint, width: geometry.width / 8,
                        height: geometry.height, mipmapped: false)
                    desc.usage = [.shaderRead]
                    texture = device.makeTexture(descriptor: desc)
                    textureGeometry = geometry
                }
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, geometry.width / 8, geometry.height),
                    mipmapLevel: 0, withBytes: staging, bytesPerRow: geometry.width / 8)
            }
            guard let texture else { return }

            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            var tint = phosphor
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
            // The geometry the texture actually holds, not what the terminal
            // may have resized to since.
            var size = SIMD2<UInt32>(UInt32(textureGeometry.width), UInt32(textureGeometry.height))
            enc.setFragmentBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
