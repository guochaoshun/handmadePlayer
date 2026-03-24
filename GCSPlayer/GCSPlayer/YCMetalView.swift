import UIKit
import MetalKit

// -----------------------------------------------------------------------------
// [核心组件] Metal 视频渲染视图
// 接收 FFmpeg 解码后的 YUV420P 数据，利用 GPU 硬件加速转换为 RGB 并显示到屏幕上
// 
// 为什么不用 UIImageView 或者 CALayer？
// 1. 性能：UIImageView 只能显示 UIImage (即 RGB 数据)，把 YUV 强转成 UIImage 需要极其昂贵的 CPU 运算，视频会严重卡顿。
// 2. 硬件加速：Metal 是苹果最底层的图形 API（类似于 Vulkan 或 Direct3D），它可以直接操作 GPU 显存和渲染管线，实现真正的零 CPU 开销渲染。
// -----------------------------------------------------------------------------
@objc public class YCMetalView: UIView {
    
    // MTKView 是 MetalKit 提供的现成 View，它内部已经封装好了和屏幕帧缓冲区的交互逻辑（双缓冲/三缓冲机制）
    private var mtkView: MTKView!
    
    // CommandQueue (命令队列)：GPU 是异步工作的，我们不能直接调用 GPU 函数，而是要把渲染指令打包成 CommandBuffer 扔进这个队列里排队执行。
    private var commandQueue: MTLCommandQueue!
    
    // RenderPipelineState (渲染管线状态)：保存了我们编译好的 Shader 代码（顶点和片元着色器）以及像素格式等配置。
    private var renderPipelineState: MTLRenderPipelineState!
    
    // YUV 纹理 (Texture)
    // 纹理本质上就是 GPU 显存中的一块二维数组（图像数据）。
    // 视频的一帧画面会被拆分成三个通道：Y(明亮度)、U(色度)、V(浓度)
    // 我们需要把这三个通道的数据分别传给 GPU，所以需要三个独立的 Texture。
    private var textureY: MTLTexture?
    private var textureU: MTLTexture?
    private var textureV: MTLTexture?
    
    private var videoWidth: Int = 0
    private var videoHeight: Int = 0
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupMetal()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetal()
    }
    
    private func setupMetal() {
        // 1. 获取系统默认的 GPU 设备
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[YCMetalView] Metal is not supported on this device")
            return
        }
        
        // 2. 初始化 MTKView (MetalKit 提供的专用渲染 View)
        mtkView = MTKView(frame: bounds, device: device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.delegate = self
        // 关键设置：我们需要自己根据视频帧率来触发 draw()，而不是根据屏幕刷新率(60Hz/120Hz)去死循环绘制
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm // 最终输出给屏幕的颜色格式
        addSubview(mtkView)
        
        // 3. 创建命令队列，用于向 GPU 发送渲染指令
        commandQueue = device.makeCommandQueue()
        
        // 4. 配置渲染管线
        setupPipeline(device: device)
    }
    
    private func setupPipeline(device: MTLDevice) {
        // 加载我们在 Shaders.metal 中编写的着色器函数
        // vertexShader: 负责计算顶点坐标（把画面撑满屏幕）
        // fragmentShader: 负责将 YUV 像素点转换成 RGB 颜色（千军万马并发算颜色）
        let library = try? device.makeDefaultLibrary()
        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")
        
        // 渲染管线描述符：告诉 GPU 我们准备怎么画这幅画
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        // 告诉 GPU 最终输出到屏幕上的颜色格式，必须和 mtkView.colorPixelFormat 一致，否则画出来是花的
        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
        
        do {
            if let v = vertexFunction, let f = fragmentFunction {
                // 编译生成管线状态对象 (这一步底层会把 Metal 代码编译成 GPU 的机器码，比较耗时，所以只在初始化时做一次)
                renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            }
        } catch {
            print("[YCMetalView] Failed to create pipeline state: \(error)")
        }
    }
    
    // -----------------------------------------------------------------------------
    // [对外接口] 接收 C/OC 层传来的 YUV 裸数据并触发渲染
    // 该方法会在主线程被调用（由 YCCorePlayer dispatch 过来），负责把 CPU 内存里的数据搬运到 GPU 显存里。
    // -----------------------------------------------------------------------------
    @objc public func display(yData: UnsafePointer<UInt8>, uData: UnsafePointer<UInt8>, vData: UnsafePointer<UInt8>,
                              width: Int, height: Int,
                              yStride: Int, uStride: Int, vStride: Int) {
        
        guard let device = mtkView.device else { return }
        
        // 拦截无效尺寸，防止 Metal 在创建纹理时崩溃
        if width <= 0 || height <= 0 {
            return
        }
        
        if videoWidth != width || videoHeight != height {
            videoWidth = width
            videoHeight = height
        }
        
        // 5. 根据 C 指针数据，创建并填充 Metal 纹理 (Texture)
        // YUV420P 格式的特点是：Y 分量(亮度)的宽高和视频宽高一致，但 U 和 V 分量(色度)的宽高只有视频的一半。
        // 这是因为人眼对颜色不敏感，所以 U 和 V 被下采样了 (Subsampling)，这极大地减少了数据量。
        //
        // .r8Unorm 表示：
        // r -> 只有一个通道（虽然叫 r 红色通道，但我们只是借用它来存单一数值，即 Y/U/V）。
        // 8 -> 这个数值占 8 bit (1 byte)。
        // Unorm -> 无符号归一化。把 0~255 的整数，映射到 GPU 里 0.0~1.0 的浮点数。
        textureY = createTexture(device: device, format: .r8Unorm, width: width, height: height, bytesPerRow: yStride, data: yData)
        textureU = createTexture(device: device, format: .r8Unorm, width: width / 2, height: height / 2, bytesPerRow: uStride, data: uData)
        textureV = createTexture(device: device, format: .r8Unorm, width: width / 2, height: height / 2, bytesPerRow: vStride, data: vData)
        
        // 6. 通知 MTKView 可以开始绘制这一帧了。这会触发底下的 draw(in view:) 回调。
        mtkView.draw()
    }
    
    private func createTexture(device: MTLDevice, format: MTLPixelFormat, width: Int, height: Int, bytesPerRow: Int, data: UnsafePointer<UInt8>) -> MTLTexture? {
        if width <= 0 || height <= 0 {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        
        // 将 C 语言的字节数组 (UnsafePointer) 直接拷贝到 GPU 纹理显存中
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        return texture
    }
}

// -----------------------------------------------------------------------------
// [绘制引擎] MTKViewDelegate
// 当我们调用 mtkView.draw() 时，系统会回调 draw(in view:)
// -----------------------------------------------------------------------------
extension YCMetalView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    
    public func draw(in view: MTKView) {
        guard let renderPipelineState = renderPipelineState,
              let drawable = view.currentDrawable, // 获取当前屏幕的帧缓冲区
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandQueue = commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(), // 创建一个指令包
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        // 绑定渲染管线 (Shader)
        renderEncoder.setRenderPipelineState(renderPipelineState)
        
        // 把我们刚才填充好的 Y、U、V 三个纹理传递给 Fragment Shader
        // index 0, 1, 2 分别对应 Shader 代码中的 [[texture(0)]], [[texture(1)]], [[texture(2)]]
        if let ty = textureY, let tu = textureU, let tv = textureV {
            renderEncoder.setFragmentTexture(ty, index: 0)
            renderEncoder.setFragmentTexture(tu, index: 1)
            renderEncoder.setFragmentTexture(tv, index: 2)
        }
        
        // 发出绘制指令：绘制两个三角形组成一个全屏的矩形 (4个顶点)
        // 顶点坐标我们没有从 CPU 传过去，而是在 vertexShader 里直接根据 vertexID 算出来的 (硬编码)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        renderEncoder.endEncoding()
        // 告诉系统：把画好的这块显存推送到屏幕上显示
        commandBuffer.present(drawable)
        // 提交指令包给 GPU 去执行
        commandBuffer.commit()
    }
}
