import MetalKit
import SwiftUI

/// Uniforms for the fragment shader. Must match `FBUniforms` in Shaders.metal.
private struct FBUniforms {
    var screen: SIMD2<UInt32>       // the frame's own dimensions, in 5620 pixels
    var texels: SIMD2<Float>        // 5620 pixels per *device* pixel
}

/// The 5620's 1-bit screen as a Metal view: uploads the packed VRAM
/// (width/8 x height, R8Uint) when the FrameStore has a newer generation
/// and lets the fragment shader expand bits with the phosphor tint.
///
/// The screen is one of two fixed sizes, so the texture is built from whatever
/// geometry arrives with a frame rather than at configure time, and the same
/// geometry is handed to the shader.
///
/// Everything here works in *device* pixels, not points. MTKView sizes its
/// drawable from the backing scale factor, so on a Retina panel the shader has
/// 2x the samples the layout suggests — which is exactly what the footprint
/// filter needs to render a 5620 pixel as something better than a smeared
/// rectangle.
struct FramebufferView: PlatformViewRepresentable {
    let frames: FrameStore
    var phosphor: SIMD3<Float> = SIMD3(0.45, 1.0, 0.60)
    /// False when the 5620 is not the visible face. A hidden MTKView keeps its
    /// display link running and re-encodes a draw thirty times a second for a
    /// picture nobody can see — which costs most in exactly the mode that
    /// exists to cost little.
    var isActive: Bool = true

    func makePlatformView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.preferredFramesPerSecond = 30
        view.framebufferOnly = true
        // Belt and braces: autoResizeDrawable is the default, but it is the
        // single thing standing between us and a half-resolution screen, and
        // it is invisible when wrong — the picture merely looks soft.
        view.autoResizeDrawable = true
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
        view.isPaused = !isActive
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
        private var loggedScale = false
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
            // may have resized to since — and the drawable's real pixel count,
            // which is the only honest source for the sampling footprint. Note
            // `drawableSize`, not `bounds`: on a 2x display those differ by
            // exactly the factor that makes the difference visible.
            let pixels = view.drawableSize
            var uniforms = FBUniforms(
                screen: SIMD2(UInt32(textureGeometry.width), UInt32(textureGeometry.height)),
                texels: SIMD2(Float(CGFloat(textureGeometry.width) / max(pixels.width, 1)),
                              Float(CGFloat(textureGeometry.height) / max(pixels.height, 1))))
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<FBUniforms>.stride, index: 1)

            if !loggedScale, pixels.width > 1 {
                loggedScale = true
                FileHandle.standardError.write(Data("""
                    ipnx: 5620 \(textureGeometry.width)x\(textureGeometry.height) into a \
                    \(Int(pixels.width))x\(Int(pixels.height)) drawable — \
                    \(String(format: "%.2f", pixels.width / CGFloat(textureGeometry.width)))x \
                    magnification\n
                    """.utf8))
            }
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }
    }
}
